#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${B_APP:-canary-mesh-full-demo-b}"
ROLLOUT_NAME="${B_ROLLOUT:-bookinfo-b}"
SHARED_VIRTUALSERVICE="${SHARED_VIRTUALSERVICE:-full-demo-router}"
B_ROUTE_NAME="${B_ROUTE_NAME:-bookinfo-b-primary}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
ROLLOUT_FILE="full-demo/bookinfo-b/rollout.yaml"
BASELINE_MARKER="bookinfo-b-baseline-stable"
FAST_DEMO_PATH="${FAST_DEMO_PATH:-1}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed grep date head; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

if [[ "$FAST_DEMO_PATH" != "1" ]]; then
  bash scripts/check-canary-mesh-prereqs.sh
  TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-full-demo-dataplane.sh
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short --untracked-files=no >&2 || true
  die "Tracked Git changes exist; prepare/start requires a clean tracked tree"
fi

candidate_spec_in_git() {
  grep -Eq 'demo-bookinfo-revision:[[:space:]]*"?bookinfo-b-candidate-' "$ROLLOUT_FILE" &&
  grep -q 'track: canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-details-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-reviews-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-ratings-canary' "$ROLLOUT_FILE"
}
baseline_spec_in_git() {
  grep -Eq 'demo-bookinfo-revision:[[:space:]]*"?bookinfo-b-baseline-stable"?[[:space:]]*$' "$ROLLOUT_FILE" &&
  grep -q 'track: stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-details-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-reviews-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-ratings-stable' "$ROLLOUT_FILE"
}

marker="$(sed -n -E 's/^[[:space:]]*demo-bookinfo-revision:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' "$ROLLOUT_FILE" | head -1)"
phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "Local ${branch} is behind origin/${branch}; run prepare again"

if [[ "$marker" == bookinfo-b-candidate-* ]]; then
  candidate_spec_in_git || die "Existing Bookinfo B candidate declaration is incomplete"
  if (( ahead > 0 )); then
    echo "==> Resuming candidate ${marker}; pushing pending local candidate commit"
    git push origin "$branch"
  else
    echo "==> Resuming existing Bookinfo B candidate ${marker}"
  fi
else
  [[ "$marker" == "$BASELINE_MARKER" ]] || die "Unexpected Git rollout marker: ${marker:-missing}"
  baseline_spec_in_git || die "Bookinfo B Git baseline declaration is incomplete"
  (( ahead == 0 )) || die "Local ${branch} is ahead of origin/${branch}; run prepare again"
  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$BASELINE_MARKER" ]] ||
    die "Bookinfo B is not at the prepared baseline; run scripts/prepare-canary-mesh-full-demo.sh"

  marker="bookinfo-b-candidate-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Declaring full-demo Bookinfo B candidate ${marker}"
  sed -i -E "s|^([[:space:]]*demo-bookinfo-revision:[[:space:]]*).*$|\1\"${marker}\"|" "$ROLLOUT_FILE"
  sed -i -E 's#track: (stable|canary)#track: canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-details-(stable|canary)#value: bookinfo-b-details-canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-reviews-(stable|canary)#value: bookinfo-b-reviews-canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-ratings-(stable|canary)#value: bookinfo-b-ratings-canary#' "$ROLLOUT_FILE"
  git add "$ROLLOUT_FILE"
  git diff --cached --check
  git diff --cached --quiet && die "Candidate mutation produced no Git change"
  git commit -m "Start full-demo Bookinfo B canary ${marker}"
  git push origin "$branch"
fi

revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

echo "==> Waiting for Argo CD to sync candidate ${revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  app_revision="$(oc get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  operation="$(oc get application "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  [[ "$operation" != "Failed" && "$operation" != "Error" ]] || die "Argo CD failed to sync candidate ${revision:0:12}"
  [[ "$sync" == "Synced" && "$app_revision" == "$revision" ]] && break
  sleep 2
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD candidate revision ${revision}"

echo "==> Bookinfo B canary running through shared VirtualService; waiting for final pause"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  live_marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  weights="$(oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath="stable={.spec.http[?(@.name==\"${B_ROUTE_NAME}\")].route[0].weight}% canary={.spec.http[?(@.name==\"${B_ROUTE_NAME}\")].route[1].weight}%" 2>/dev/null || true)"
  printf '    phase=%s step=%s %s\n' "${phase:-unknown}" "${step:-unknown}" "${weights:-weights-unknown}"
  [[ "$phase" != "Degraded" ]] || die "Bookinfo B canary became Degraded"
  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$marker" ]]; then
    echo "==> Candidate ${marker} is already promoted; start is already satisfied"
    exit 0
  fi
  [[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" && "$live_marker" == "$marker" ]] && break
  sleep 2
done
(( SECONDS < deadline )) || die "Timed out waiting for Bookinfo B final canary pause"

if [[ "$FAST_DEMO_PATH" != "1" ]]; then TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-full-demo-dataplane.sh; fi

echo
oc argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"
echo
echo "All Bookinfo B canary gates passed. Traffic is 100% candidate at the final manual pause."
echo "Promote with: bash scripts/promote-canary-mesh-full-demo.sh"
