#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="metric-ai-demo/app/rollout.yaml"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed date; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

echo "==> Restoring stable demo image"
sed -i -E \
  's#image: ghcr.io/kdubois/argo-rollouts-quarkus-demo:[^[:space:]]+#image: ghcr.io/kdubois/argo-rollouts-quarkus-demo:v1.stable#' \
  "$ROLLOUT_FILE"

trigger="ai-reset-$(date -u +%Y%m%dT%H%M%SZ)-$$"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"$trigger\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
git commit -m "Restore metric AI stable baseline"
git push origin "$branch"

revision="$(git rev-parse HEAD)"

oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for stable baseline"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

  printf '    sync=%s revision=%s rollout=%s\n' \
    "${sync:-unknown}" "${got:0:12}" "${phase:-unknown}"

  [[ "$sync" == "Synced" && "$got" == "$revision" && "$phase" == "Healthy" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring stable baseline"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Stable metric-AI baseline restored."
