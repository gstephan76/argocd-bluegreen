#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
B_APP="${B_APP:-canary-mesh-multi-bookinfo-b}"
APP_NAME="$B_APP"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
A_VIRTUALSERVICE="${A_VIRTUALSERVICE:-bookinfo-a-rollout}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
ROLLOUT_NAME="$B_ROLLOUT"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc jq curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
export NAMESPACE APP_NAME ARGOCD_NAMESPACE ROLLOUT_NAME
mesh_enable_failure_diagnostics

bash scripts/check-canary-mesh-prereqs.sh
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

assert_bookinfo_a_parked() {
  local phase stable current marker details reviews ratings stable_weight canary_weight
  phase="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  marker="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  details="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
  reviews="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
  ratings="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
  stable_weight="$(oc get virtualservice.networking.istio.io "$A_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
  canary_weight="$(oc get virtualservice.networking.istio.io "$A_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" &&
     "$marker" == "bookinfo-a-baseline-stable" &&
     "$details" == "bookinfo-a-details-stable" &&
     "$reviews" == "bookinfo-a-reviews-stable" &&
     "$ratings" == "bookinfo-a-ratings-stable" &&
     "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
    die "Bookinfo A Rollout is not parked at its baseline; run scripts/prepare-canary-mesh-multi-bookinfo.sh"
}

assert_bookinfo_a_parked

phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
[[ "$marker" == bookinfo-b-candidate-* ]] || die "Current Bookinfo B desired revision is not a candidate"

if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]]; then
  details="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
  reviews="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
  ratings="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
  stable_weight="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
  canary_weight="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
  [[ "$details" == "bookinfo-b-details-canary" && "$reviews" == "bookinfo-b-reviews-canary" && "$ratings" == "bookinfo-b-ratings-canary" ]] ||
    die "Already-promoted Bookinfo B candidate is not isolated to its canary downstream stack"
  [[ "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
    die "Already-promoted Bookinfo B has unexpected routing"
  TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh
  assert_bookinfo_a_parked
  host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
  body_a="$(curl -sk "https://${host_a}/productpage" || true)"
  grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A is not healthy while verifying an already-promoted Bookinfo B"
  echo "==> Bookinfo B candidate ${marker} is already promoted and verified; no action required"
  exit 0
fi

[[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" ]] ||
  die "Bookinfo B Rollout is not at the final 100% manual approval pause"

TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh

successful="$(
  oc get analysisrun -n "$NAMESPACE" -o json |
    jq --arg app "$ROLLOUT_NAME" --arg hash "$current" '
      [.items[] |
        select(any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $app)) |
        select(.metadata.labels["rollouts-pod-template-hash"] == $hash) |
        select(.status.phase == "Successful")
      ] | length
    '
)"
(( successful >= 5 )) || die "Expected five Successful Bookinfo B AnalysisRuns; found ${successful}"

candidate_hash="$current"
echo "==> Promoting verified Bookinfo B candidate ${candidate_hash}"
oc argo rollouts promote "$ROLLOUT_NAME" -n "$NAMESPACE"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}"
  [[ "$phase" != "Degraded" ]] || die "Bookinfo B Rollout became Degraded during promotion"
  [[ "$phase" == "Healthy" && "$stable" == "$candidate_hash" && "$current" == "$candidate_hash" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Bookinfo B candidate to become stable"

stable_weight="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
canary_weight="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
[[ "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
  die "Bookinfo B post-promotion routing is not normalized"

assert_bookinfo_a_parked
host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
body_a="$(curl -sk "https://${host_a}/productpage" || true)"
grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A Rollout left its baseline route during Bookinfo B promotion"

echo
oc argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"
echo
echo "Bookinfo B promotion complete. The verified candidate is now stable."
echo "Bookinfo A Rollout remained parked at its 100/0 baseline."
echo "Repeated promotion is a no-op for this Bookinfo B candidate."
echo "Use scripts/prepare-canary-mesh-multi-bookinfo.sh before starting another cycle."
