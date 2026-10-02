#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
export NAMESPACE APP_NAME
mesh_enable_failure_diagnostics

bash scripts/check-canary-mesh-prereqs.sh
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
[[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" ]] ||
  die "Rollout is not at the final 100% manual approval pause"
[[ "$marker" == bookinfo-candidate-* ]] || die "Current desired revision is not a Bookinfo candidate"

TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-bookinfo-dataplane.sh

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

candidate_hash="$current"
echo "==> Promoting verified whole-Bookinfo candidate ${candidate_hash}"
oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}"
  [[ "$phase" != "Degraded" ]] || die "Rollout became Degraded during promotion"
  [[ "$phase" == "Healthy" && "$stable" == "$candidate_hash" && "$current" == "$candidate_hash" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for whole-Bookinfo candidate to become stable"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Promotion complete. The verified whole-Bookinfo candidate is now the active stable revision."
echo "Use scripts/prepare-canary-mesh-bookinfo.sh before starting another canary cycle."
