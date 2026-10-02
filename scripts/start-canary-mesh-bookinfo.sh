#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-mesh-bookinfo/rollout.yaml"
BASELINE_MARKER="bookinfo-baseline-stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed jq date; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
export NAMESPACE APP_NAME ARGOCD_NAMESPACE
mesh_enable_failure_diagnostics

bash scripts/check-canary-mesh-prereqs.sh
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! git diff --quiet || ! git diff --cached --quiet; then die "Tracked Git changes exist"; fi
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
[[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$BASELINE_MARKER" ]] ||
  die "Run scripts/prepare-canary-mesh-bookinfo.sh before starting a new candidate"

marker="bookinfo-candidate-$(date -u +%Y%m%dT%H%M%SZ)"
echo "==> Declaring complete Bookinfo candidate ${marker}"

sed -i -E "s#demo-bookinfo-revision: \".*\"#demo-bookinfo-revision: \"${marker}\"#" "$ROLLOUT_FILE"
sed -i -E 's#track: (stable|canary)#track: canary#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-details-(stable|canary)#value: bookinfo-details-canary#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-reviews-(stable|canary)#value: bookinfo-reviews-canary#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-ratings-(stable|canary)#value: bookinfo-ratings-canary#' "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
git commit -m "Start whole-Bookinfo canary ${marker}"
git push origin "$branch"
revision="$(git rev-parse HEAD)"

oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
  die "Argo CD did not reconcile exact revision ${revision}"

echo "==> Waiting for 10/25/50/75/100 whole-application canary gates"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  weights="$(oc get virtualservice "$APP_NAME" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"
  printf '    phase=%s step=%s stable=%s current=%s %s\n' "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}" "${weights:-weights-unknown}"
  [[ "$phase" != "Degraded" ]] || die "Whole-Bookinfo canary became Degraded"
  [[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for final whole-Bookinfo canary pause"

details="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}')"
reviews="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}')"
ratings="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}')"
[[ "$details" == "bookinfo-details-canary" &&
   "$reviews" == "bookinfo-reviews-canary" &&
   "$ratings" == "bookinfo-ratings-canary" ]] ||
  die "Candidate productpage is not isolated to the complete canary downstream stack"

successful="$(
  oc get analysisrun -n "$NAMESPACE" -o json |
    jq --arg app "$APP_NAME" --arg hash "$current" '
      [.items[] |
        select(any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $app)) |
        select(.metadata.labels["rollouts-pod-template-hash"] == $hash) |
        select(.status.phase == "Successful")
      ] | length
    '
)"
(( successful >= 5 )) || die "Expected five Successful candidate AnalysisRuns; found ${successful}"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "All whole-Bookinfo canary gates passed. Traffic is 100% candidate at the final manual pause."
echo "Sample it with: REQUESTS=200 bash scripts/sample-canary-mesh-bookinfo.sh"
echo "Promote with: bash scripts/promote-canary-mesh-bookinfo.sh"
