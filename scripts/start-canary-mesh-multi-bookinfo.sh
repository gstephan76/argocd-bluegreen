#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
B_APP="${B_APP:-canary-mesh-multi-bookinfo-b}"
APP_NAME="$B_APP"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
ROLLOUT_NAME="$B_ROLLOUT"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-mesh-multi-bookinfo/bookinfo-b/rollout.yaml"
BASELINE_MARKER="bookinfo-b-baseline-stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed grep jq date head curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
export NAMESPACE APP_NAME ARGOCD_NAMESPACE ROLLOUT_NAME
mesh_enable_failure_diagnostics

bash scripts/check-canary-mesh-prereqs.sh
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

echo "==> Verifying Git repository state"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Tracked Git changes:" >&2
  git status --short --untracked-files=no >&2 || true
  die "Tracked Git changes exist; commit or restore them before running start"
fi

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "Local ${branch} is ${behind} commit(s) behind origin/${branch}"
if (( ahead > 0 )); then
  echo "==> Local ${branch} is ${ahead} commit(s) ahead; pushing before start"
  git push origin "$branch"
fi
git fetch origin "$branch"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/${branch}")" ]] ||
  die "Local branch is not synchronized with origin/${branch}"

assert_bookinfo_a_parked() {
  local phase stable current marker details reviews ratings stable_weight canary_weight
  phase="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  marker="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  details="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
  reviews="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
  ratings="$(oc get rollout "$A_ROLLOUT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
  stable_weight="$(oc get virtualservice.networking.istio.io bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
  canary_weight="$(oc get virtualservice.networking.istio.io bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" &&
     "$marker" == "bookinfo-a-baseline-stable" &&
     "$details" == "bookinfo-a-details-stable" &&
     "$reviews" == "bookinfo-a-reviews-stable" &&
     "$ratings" == "bookinfo-a-ratings-stable" &&
     "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
    die "Bookinfo A Rollout is not parked at its baseline; run scripts/prepare-canary-mesh-multi-bookinfo.sh"
}

assert_bookinfo_a_parked

candidate_spec_in_git() {
  grep -q 'demo-bookinfo-revision: "bookinfo-b-candidate-' "$ROLLOUT_FILE" &&
  grep -q 'track: canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-details-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-reviews-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-ratings-canary' "$ROLLOUT_FILE"
}

baseline_spec_in_git() {
  grep -q 'demo-bookinfo-revision: "bookinfo-b-baseline-stable"' "$ROLLOUT_FILE" &&
  grep -q 'track: stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-details-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-reviews-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-b-ratings-stable' "$ROLLOUT_FILE"
}

marker="$(sed -n -E 's/^[[:space:]]*demo-bookinfo-revision:[[:space:]]*"([^"]+)".*/\1/p' "$ROLLOUT_FILE" | head -1)"
revision="$(git rev-parse HEAD)"

phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"

if [[ "$marker" == bookinfo-b-candidate-* ]]; then
  candidate_spec_in_git || die "Git candidate marker exists but Bookinfo B candidate targets are incomplete"
  echo "==> Existing Bookinfo B candidate ${marker} already declared in Git; resuming idempotently"

  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$marker" ]]; then
    details="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
    reviews="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
    ratings="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
    [[ "$details" == "bookinfo-b-details-canary" &&
       "$reviews" == "bookinfo-b-reviews-canary" &&
       "$ratings" == "bookinfo-b-ratings-canary" ]] ||
      die "Promoted Bookinfo B candidate is not isolated to its canary downstream stack"
    TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh
    assert_bookinfo_a_parked
    host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
    body_a="$(curl -sk "https://${host_a}/productpage" || true)"
    grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A is not healthy while verifying an already-promoted Bookinfo B"
    echo "==> Candidate ${marker} is already promoted; start is already satisfied"
    echo "Run scripts/prepare-canary-mesh-multi-bookinfo.sh before beginning a new candidate cycle."
    exit 0
  fi
else
  [[ "$marker" == "$BASELINE_MARKER" ]] || die "Unexpected Git rollout marker: ${marker:-missing}"
  baseline_spec_in_git || die "Git baseline marker exists but Bookinfo B stable targets are incomplete"
  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$BASELINE_MARKER" ]] ||
    die "Run scripts/prepare-canary-mesh-multi-bookinfo.sh before starting a new Bookinfo B candidate"

  marker="bookinfo-b-candidate-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "==> Declaring complete Bookinfo B candidate ${marker}"

  sed -i -E "s#demo-bookinfo-revision: \".*\"#demo-bookinfo-revision: \"${marker}\"#" "$ROLLOUT_FILE"
  sed -i -E 's#track: (stable|canary)#track: canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-details-(stable|canary)#value: bookinfo-b-details-canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-reviews-(stable|canary)#value: bookinfo-b-reviews-canary#' "$ROLLOUT_FILE"
  sed -i -E 's#value: bookinfo-b-ratings-(stable|canary)#value: bookinfo-b-ratings-canary#' "$ROLLOUT_FILE"

  git add "$ROLLOUT_FILE"
  git diff --cached --check
  git diff --cached --quiet && die "Candidate mutation produced no Git change from a verified baseline"
  git commit -m "Start multi-Bookinfo B canary ${marker}"

  git fetch origin "$branch"
  read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
  (( behind == 0 )) || die "origin/${branch} advanced while declaring Bookinfo B candidate"
  (( ahead > 0 )) && git push origin "$branch"
  git fetch origin "$branch"
  revision="$(git rev-parse HEAD)"
  [[ "$revision" == "$(git rev-parse "origin/${branch}")" ]] || die "Candidate push verification failed"
fi

revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
  die "Argo CD did not reconcile exact revision ${revision}"

echo "==> Waiting for Bookinfo B 10/25/50/75/100 whole-application canary gates"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  live_marker="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  weights="$(oc get virtualservice bookinfo-b -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"
  printf '    phase=%s step=%s stable=%s current=%s marker=%s %s\n' \
    "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}" "${live_marker:-missing}" "${weights:-weights-unknown}"

  [[ "$phase" != "Degraded" ]] || die "Bookinfo B canary became Degraded"

  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$marker" ]]; then
    details="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
    reviews="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
    ratings="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
    [[ "$details" == "bookinfo-b-details-canary" &&
       "$reviews" == "bookinfo-b-reviews-canary" &&
       "$ratings" == "bookinfo-b-ratings-canary" ]] ||
      die "Promoted Bookinfo B candidate is not isolated to its canary downstream stack"
    TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh
    echo "==> Candidate ${marker} is already promoted; start is already satisfied"
    exit 0
  fi

  [[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" && "$live_marker" == "$marker" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Bookinfo B final canary pause"

details="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}')"
reviews="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}')"
ratings="$(oc get rollout "$ROLLOUT_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}')"
[[ "$details" == "bookinfo-b-details-canary" &&
   "$reviews" == "bookinfo-b-reviews-canary" &&
   "$ratings" == "bookinfo-b-ratings-canary" ]] ||
  die "Bookinfo B candidate is not isolated to its complete canary downstream stack"

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

assert_bookinfo_a_parked
host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
body_a="$(curl -sk "https://${host_a}/productpage" || true)"
grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A Rollout left its baseline route during Bookinfo B rollout"

echo
oc argo rollouts get rollout "$ROLLOUT_NAME" -n "$NAMESPACE"
echo
echo "All Bookinfo B canary gates passed. Traffic is 100% candidate at the final manual pause."
echo "Bookinfo A Rollout remained parked at its 100/0 baseline throughout the rollout."
echo "Repeated start invocations reuse candidate ${marker}; they do not create another revision."
echo "Sample both routes with: REQUESTS_B=200 bash scripts/sample-canary-mesh-multi-bookinfo.sh"
echo "Promote with: bash scripts/promote-canary-mesh-multi-bookinfo.sh"
