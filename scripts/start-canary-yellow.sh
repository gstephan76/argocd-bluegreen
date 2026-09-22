#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-demo/rollout.yaml"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed; do command -v "$c" >/dev/null || die "$c not found"; done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! git diff --quiet || ! git diff --cached --quiet; then die "Tracked Git changes exist"; fi
branch="$(git branch --show-current)"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"
case "$image" in
  argoproj/rollouts-demo:blue)
    sed -i 's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:yellow#' "$ROLLOUT_FILE"
    git add "$ROLLOUT_FILE"
    git diff --cached --check
    git commit -m "Deploy yellow canary"
    git push origin "$branch"
    ;;
  argoproj/rollouts-demo:yellow) echo "Git already requests YELLOW" ;;
  *) die "Unexpected image: $image" ;;
esac

rev="$(git rev-parse HEAD)"

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME"   -n "$ARGOCD_NAMESPACE"   argocd.argoproj.io/refresh=hard   --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${rev:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  [[ "$sync" == "Synced" && "$got" == "$rev" ]] && break
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for 20% Prometheus analysis to pass and reach the manual pause"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  printf '    phase=%s step=%s\n' "${phase:-unknown}" "${step:-unknown}"

  if [[ "$phase" == "Degraded" ]]; then
    echo
    oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true
    oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
    die "Canary analysis failed. The rollout was not promoted."
  fi

  [[ "$phase" == "Paused" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for successful canary analysis and pause"

echo
echo "==> AnalysisRuns"
oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "The 20% Prometheus gate has passed. Manual promotion is now allowed:"
echo "  oc argo rollouts promote $APP_NAME -n $NAMESPACE"
echo "Abort:"
echo "  oc argo rollouts abort $APP_NAME -n $NAMESPACE"
