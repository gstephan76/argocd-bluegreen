#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-demo/rollout.yaml"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed rg date; do command -v "$c" >/dev/null || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

previous_rollout_revision="$(oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
  2>/dev/null || true)"

image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"
case "$image" in
  argoproj/rollouts-demo:blue)
    echo "==> Changing desired image BLUE -> YELLOW"
    sed -i 's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:yellow#' "$ROLLOUT_FILE"
    ;;
  argoproj/rollouts-demo:yellow)
    echo "==> Git already requests YELLOW"
    ;;
  *)
    die "Unexpected image: $image"
    ;;
esac

rg -q 'demo-rollout-revision:' "$ROLLOUT_FILE" || \
  die "demo-rollout-revision annotation not found in $ROLLOUT_FILE"

trigger="prometheus-$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "==> Triggering fresh canary revision: $trigger"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"$trigger\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
git commit -m "Trigger Prometheus-gated canary revision"
git push origin "$branch"

rev="$(git rev-parse HEAD)"

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${rev:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"

  [[ "$sync" == "Synced" && "$got" == "$rev" ]] && break

  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for Argo Rollouts to observe a new rollout revision"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  rollout_revision="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
    2>/dev/null || true)"

  printf '    previous=%s current=%s\n' \
    "${previous_rollout_revision:-none}" \
    "${rollout_revision:-none}"

  [[ -n "$rollout_revision" &&
     "$rollout_revision" != "$previous_rollout_revision" ]] && break

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for a new Rollout revision"

echo "==> Automatic validation: 33% -> HTTP-200 gate -> 66% -> HTTP-200 gate -> 100% -> HTTP-200 gate -> final pause"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

  printf '    phase=%s step=%s stable=%s current=%s\n' \
    "${phase:-unknown}" "${step:-unknown}" \
    "${stable:-none}" "${current:-none}"

  if [[ "$phase" == "Degraded" ]]; then
    echo
    oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true
    echo
    oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
    die "Prometheus HTTP-200 gate failed; rollout did not progress"
  fi

  # This strategy has a single pause, after the successful 100% analysis.
  if [[ "$phase" == "Paused" ]]; then
    break
  fi

  if [[ "$phase" == "Healthy" &&
        -n "$stable" &&
        "$stable" == "$current" ]]; then
    die "Rollout became stable without reaching the expected final approval pause"
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for the final approval pause"

echo
echo "==> AnalysisRuns"
oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"

echo
echo "All Prometheus gates passed at 33%, 66%, and 100%."
echo "The canary is at 100% exposure but has NOT been declared stable."
echo
echo "Final manual approval:"
echo "  bash scripts/promote-canary-stable.sh"
echo
echo "Direct equivalent:"
echo "  oc argo rollouts promote $APP_NAME -n $NAMESPACE"
