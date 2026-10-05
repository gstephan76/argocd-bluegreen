#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
SHARED_APP="${SHARED_APP:-canary-mesh-full-demo-shared}"
A_APP="${A_APP:-canary-mesh-full-demo-a}"
B_APP="${B_APP:-canary-mesh-full-demo-b}"
APP_NAME="$B_APP"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
ROLLOUT_NAME="$B_ROLLOUT"
SHARED_VIRTUALSERVICE="${SHARED_VIRTUALSERVICE:-full-demo-router}"
A_ROUTE_NAME="${A_ROUTE_NAME:-bookinfo-a-primary}"
B_ROUTE_NAME="${B_ROUTE_NAME:-bookinfo-b-primary}"
DEMO_ROUTE="${DEMO_ROUTE:-full-demo}"
TARGET_HEADER="${TARGET_HEADER:-x-bookinfo-target}"
A_HEADER_VALUE="${A_HEADER_VALUE:-a}"
B_HEADER_VALUE="${B_HEADER_VALUE:-b}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
CLEAN_ROLLOUT_HISTORY="${CLEAN_ROLLOUT_HISTORY:-1}"
A_ROLLOUT_FILE="full-demo/bookinfo-a/rollout.yaml"
B_ROLLOUT_FILE="full-demo/bookinfo-b/rollout.yaml"
A_BASELINE_MARKER="bookinfo-a-baseline-stable"
B_BASELINE_MARKER="bookinfo-b-baseline-stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed grep curl jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
export NAMESPACE APP_NAME ARGOCD_NAMESPACE ROLLOUT_NAME
mesh_enable_failure_diagnostics

# prepare intentionally owns the heavy validation for the demo.
bash scripts/check-canary-mesh-prereqs.sh
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

echo "==> Verifying Git repository state"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
if ! git diff --quiet || ! git diff --cached --quiet; then
  git status --short --untracked-files=no >&2 || true
  die "Tracked Git changes exist; commit or restore them before running prepare"
fi
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "Local ${branch} is behind origin/${branch}"
if (( ahead > 0 )); then git push origin "$branch"; fi
git fetch origin "$branch"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/${branch}")" ]] || die "Git state is not synchronized"

restore_baseline_file() {
  local file="$1" instance="$2" marker="$3"
  sed -i -E "s#^([[:space:]]*demo-bookinfo-revision:[[:space:]]*).*$#\1\"${marker}\"#" "$file"
  sed -i -E 's#track: (stable|canary)#track: stable#' "$file"
  sed -i -E "s#value: ${instance}-details-(stable|canary)#value: ${instance}-details-stable#" "$file"
  sed -i -E "s#value: ${instance}-reviews-(stable|canary)#value: ${instance}-reviews-stable#" "$file"
  sed -i -E "s#value: ${instance}-ratings-(stable|canary)#value: ${instance}-ratings-stable#" "$file"
}

echo "==> Restoring both full-demo Rollout baselines in Git"
restore_baseline_file "$A_ROLLOUT_FILE" bookinfo-a "$A_BASELINE_MARKER"
restore_baseline_file "$B_ROLLOUT_FILE" bookinfo-b "$B_BASELINE_MARKER"
git add "$A_ROLLOUT_FILE" "$B_ROLLOUT_FILE"
git diff --cached --check
if ! git diff --cached --quiet; then git commit -m "Restore full-demo rollout baselines"; fi

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "origin/${branch} advanced during prepare"
(( ahead > 0 )) && git push origin "$branch"
git fetch origin "$branch"
revision="$(git rev-parse HEAD)"
[[ "$revision" == "$(git rev-parse "origin/${branch}")" ]] || die "Push verification failed"
git diff --quiet && git diff --cached --quiet || die "Tracked Git changes remain after prepare Git phase"

echo "==> Reconciling shared routing first, then both independent Bookinfo Applications"
if ! oc get application "$SHARED_APP" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 ||
   ! oc get application "$A_APP" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 ||
   ! oc get application "$B_APP" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  bash scripts/deploy-canary-mesh-full-demo.sh
else
  oc annotate application "$SHARED_APP" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  mesh_wait_argocd_revision "$SHARED_APP" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" || die "Shared app did not reconcile ${revision}"
  for app in "$A_APP" "$B_APP"; do
    oc annotate application "$app" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
    mesh_wait_argocd_revision "$app" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" || die "${app} did not reconcile ${revision}"
  done
fi

route_weight() {
  local route="$1" index="$2"
  oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath="{.spec.http[?(@.name==\"${route}\")].route[${index}].weight}" 2>/dev/null || true
}
recover_rollout_baseline() {
  local rollout="$1" instance="$2" marker_expected="$3" route_name="$4" deadline promotion_requested=0
  local phase stable current marker details reviews ratings sw cw
  echo "==> Recovering ${instance} trusted stable baseline"
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    phase="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    stable="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
    current="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
    marker="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
    details="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
    reviews="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
    ratings="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
    sw="$(route_weight "$route_name" 0)"; cw="$(route_weight "$route_name" 1)"
    printf '    %-10s phase=%s stable=%s current=%s routing=%s/%s\n' "$instance" "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${sw:-?}" "${cw:-?}"
    if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$marker" == "$marker_expected" && "$details" == "${instance}-details-stable" && "$reviews" == "${instance}-reviews-stable" && "$ratings" == "${instance}-ratings-stable" && "$sw" == "100" && "$cw" == "0" ]]; then return 0; fi
    if [[ "$marker" == "$marker_expected" && -n "$current" && "$stable" != "$current" && "$promotion_requested" == 0 ]]; then
      oc argo rollouts promote --full "$rollout" -n "$NAMESPACE"
      promotion_requested=1
    fi
    [[ "$phase" != "Degraded" ]] || die "${instance} baseline recovery became Degraded"
    sleep "$POLL_SECONDS"
  done
  die "Timed out restoring ${instance} baseline"
}
recover_rollout_baseline "$A_ROLLOUT" bookinfo-a "$A_BASELINE_MARKER" "$A_ROUTE_NAME"
recover_rollout_baseline "$B_ROLLOUT" bookinfo-b "$B_BASELINE_MARKER" "$B_ROUTE_NAME"

cleanup_rollout_history() {
  local rollout="$1" instance="$2" phase stable current
  local -a analysis_runs stale_replicasets
  phase="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
  stable="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}')"
  current="$(oc get rollout "$rollout" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}')"
  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]] || die "Refusing to clean ${instance} before stable convergence"
  mapfile -t analysis_runs < <(oc get analysisrun -n "$NAMESPACE" -o json | jq -r --arg r "$rollout" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="Rollout" and .name==$r)) | .metadata.name')
  (( ${#analysis_runs[@]} == 0 )) || oc delete analysisrun -n "$NAMESPACE" "${analysis_runs[@]}" --wait=true >/dev/null
  mapfile -t stale_replicasets < <(oc get replicaset -n "$NAMESPACE" -o json | jq -r --arg r "$rollout" --arg keep "$stable" '.items[] | select(any(.metadata.ownerReferences[]?; .kind=="Rollout" and .name==$r)) | select((.metadata.labels["rollouts-pod-template-hash"] // "") != $keep) | .metadata.name')
  (( ${#stale_replicasets[@]} == 0 )) || oc delete replicaset -n "$NAMESPACE" "${stale_replicasets[@]}" --wait=true >/dev/null
}
case "$CLEAN_ROLLOUT_HISTORY" in
  1|true|TRUE|yes|YES) cleanup_rollout_history "$A_ROLLOUT" bookinfo-a; cleanup_rollout_history "$B_ROLLOUT" bookinfo-b ;;
  0|false|FALSE|no|NO) echo "==> Preserving Rollout history" ;;
  *) die "CLEAN_ROLLOUT_HISTORY must be 1/0, true/false, or yes/no" ;;
esac

TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-full-demo-dataplane.sh
[[ "$(route_weight "$A_ROUTE_NAME" 0)" == 100 && "$(route_weight "$A_ROUTE_NAME" 1)" == 0 ]] || die "Bookinfo A shared route is not 100/0"
[[ "$(route_weight "$B_ROUTE_NAME" 0)" == 100 && "$(route_weight "$B_ROUTE_NAME" 1)" == 0 ]] || die "Bookinfo B shared route is not 100/0"

host="$(oc get route "$DEMO_ROUTE" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
body_a="$(curl -sk -H "${TARGET_HEADER}: ${A_HEADER_VALUE}" "https://${host}/productpage" || true)"
body_b="$(curl -sk -H "${TARGET_HEADER}: ${B_HEADER_VALUE}" "https://${host}/productpage" || true)"
grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A baseline header route is not healthy"
grep -q 'text-black-500' <<<"$body_b" || die "Bookinfo B baseline header route is not healthy"

git fetch origin "$branch"
[[ "$(git rev-parse HEAD)" == "$revision" && "$(git rev-parse "origin/${branch}")" == "$revision" ]] || die "Git revision changed during recovery"
echo "==> Verified Bookinfo A and B at 100/0 through shared VirtualService ${SHARED_VIRTUALSERVICE}"
echo "==> Verified header router: ${TARGET_HEADER}=${A_HEADER_VALUE}|${B_HEADER_VALUE}"
echo "==> Verified Git source of truth: ${branch}@${revision:0:12}"
echo
oc argo rollouts get rollout "$A_ROLLOUT" -n "$NAMESPACE"
echo
oc argo rollouts get rollout "$B_ROLLOUT" -n "$NAMESPACE"
echo "full-demo baseline is ready. Next: bash scripts/start-canary-mesh-full-demo.sh"
