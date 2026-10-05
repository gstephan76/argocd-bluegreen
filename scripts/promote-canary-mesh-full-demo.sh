#!/usr/bin/env bash
set -Eeuo pipefail
NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
ROLLOUT_NAME="${B_ROLLOUT:-bookinfo-b}"
FAST_DEMO_PATH="${FAST_DEMO_PATH:-1}"
die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc not found"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$FAST_DEMO_PATH" != "1" ]]; then
  bash scripts/check-canary-mesh-prereqs.sh
  TIMEOUT_SECONDS=300 bash scripts/check-canary-mesh-full-demo-dataplane.sh
fi
phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
[[ "$marker" == bookinfo-b-candidate-* ]] || die "Current Bookinfo B revision is not a candidate"
if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]]; then echo "==> Bookinfo B candidate ${marker} is already promoted; no action required"; exit 0; fi
[[ "$phase" == "Paused" ]] || die "Bookinfo B is not paused for promotion (phase=${phase:-unknown})"
[[ "$step" == "10" ]] || die "Bookinfo B is not at the final approval pause (step=${step:-unknown})"
[[ -n "$current" && "$stable" != "$current" ]] || die "No pending Bookinfo B candidate exists"
candidate_hash="$current"
echo "==> Promoting Bookinfo B candidate ${candidate_hash}"
oc argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}"
  [[ "$phase" != "Degraded" ]] || die "Bookinfo B became Degraded during promotion"
  [[ "$phase" == "Healthy" && "$stable" == "$candidate_hash" && "$current" == "$candidate_hash" ]] && break
  sleep 2
done
(( SECONDS < deadline )) || die "Timed out waiting for Bookinfo B promotion"
if [[ "$FAST_DEMO_PATH" != "1" ]]; then TIMEOUT_SECONDS=300 bash scripts/check-canary-mesh-full-demo-dataplane.sh; fi
echo
oc argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"
echo
echo "Bookinfo B promotion complete."
