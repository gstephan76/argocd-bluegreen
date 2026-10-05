#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
A_APP="${A_APP:-canary-mesh-multi-bookinfo-a}"
B_APP="${B_APP:-canary-mesh-multi-bookinfo-b}"
APP_NAME="$B_APP"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
ROLLOUT_NAME="$B_ROLLOUT"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
A_ROLLOUT_FILE="canary-mesh-multi-bookinfo/bookinfo-a/rollout.yaml"
B_ROLLOUT_FILE="canary-mesh-multi-bookinfo/bookinfo-b/rollout.yaml"
A_BASELINE_MARKER="bookinfo-a-baseline-stable"
B_BASELINE_MARKER="bookinfo-b-baseline-stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed grep curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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
  die "Tracked Git changes exist; commit or restore them before running prepare"
fi

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "Local ${branch} is ${behind} commit(s) behind origin/${branch}; update/reconcile it before running prepare"
if (( ahead > 0 )); then
  echo "==> Local ${branch} is ${ahead} commit(s) ahead of origin/${branch}; pushing"
  git push origin "$branch"
fi

git fetch origin "$branch"
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/${branch}")"
[[ "$local_head" == "$remote_head" ]] || die "Git state is not synchronized after preflight"
echo "==> Git preflight synchronized at ${local_head:0:12}"

restore_baseline_file() {
  local file="$1" instance="$2" marker="$3"
  sed -i -E "s#demo-bookinfo-revision: \".*\"#demo-bookinfo-revision: \"${marker}\"#" "$file"
  sed -i -E 's#track: (stable|canary)#track: stable#' "$file"
  sed -i -E "s#value: ${instance}-details-(stable|canary)#value: ${instance}-details-stable#" "$file"
  sed -i -E "s#value: ${instance}-reviews-(stable|canary)#value: ${instance}-reviews-stable#" "$file"
  sed -i -E "s#value: ${instance}-ratings-(stable|canary)#value: ${instance}-ratings-stable#" "$file"
}

echo "==> Restoring both Bookinfo Rollout baselines in Git"
restore_baseline_file "$A_ROLLOUT_FILE" bookinfo-a "$A_BASELINE_MARKER"
restore_baseline_file "$B_ROLLOUT_FILE" bookinfo-b "$B_BASELINE_MARKER"

git add "$A_ROLLOUT_FILE" "$B_ROLLOUT_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already declares both Bookinfo baselines"
else
  echo "==> Committing multi-Bookinfo baselines"
  git commit -m "Restore multi-Bookinfo rollout baselines"
fi

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) || die "origin/${branch} advanced during prepare; refusing automatic merge/rebase"
if (( ahead > 0 )); then
  echo "==> Pushing ${ahead} recovery commit(s) to origin/${branch}"
  git push origin "$branch"
fi

git fetch origin "$branch"
revision="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/${branch}")"
[[ "$revision" == "$remote_head" ]] || die "Push verification failed"
git diff --quiet && git diff --cached --quiet || die "Tracked Git changes remain after baseline commit/push"
echo "==> Git baselines committed/pushed and verified at ${revision:0:12}"

if ! oc get applications.argoproj.io "$A_APP" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 ||
   ! oc get applications.argoproj.io "$B_APP" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  bash scripts/deploy-canary-mesh-multi-bookinfo.sh
else
  for app in "$A_APP" "$B_APP"; do
    oc annotate applications.argoproj.io "$app" -n "$ARGOCD_NAMESPACE" \
      argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  done
fi

echo "==> Waiting for both Bookinfo Argo CD Applications at revision ${revision:0:12}"
for app in "$A_APP" "$B_APP"; do
  mesh_wait_argocd_revision "$app" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
    die "Argo CD Application ${app} did not reconcile exact revision ${revision}"
done

recover_rollout_baseline() {
  local rollout="$1" instance="$2" baseline_marker="$3"
  local deadline promotion_requested=0 phase stable current marker details reviews ratings stable_weight canary_weight
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
    stable_weight="$(oc get virtualservice.networking.istio.io "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
    canary_weight="$(oc get virtualservice.networking.istio.io "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
    printf '    %-10s phase=%s stable=%s current=%s marker=%s routing=stable:%s%%/canary:%s%%\n' \
      "$instance" "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${marker:-missing}" \
      "${stable_weight:-unknown}" "${canary_weight:-unknown}"

    if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" &&
          "$marker" == "$baseline_marker" &&
          "$details" == "${instance}-details-stable" &&
          "$reviews" == "${instance}-reviews-stable" &&
          "$ratings" == "${instance}-ratings-stable" &&
          "$stable_weight" == "100" && "$canary_weight" == "0" ]]; then
      return 0
    fi

    if [[ "$marker" == "$baseline_marker" && -n "$current" && "$stable" != "$current" && "$promotion_requested" == "0" ]]; then
      echo "==> Fully promoting verified ${instance} baseline recovery"
      oc argo rollouts promote --full "$rollout" -n "$NAMESPACE"
      promotion_requested=1
    fi

    [[ "$phase" != "Degraded" ]] || die "${instance} baseline recovery became Degraded"
    sleep "$POLL_SECONDS"
  done
  die "Timed out restoring ${instance} stable baseline"
}

recover_rollout_baseline "$A_ROLLOUT" bookinfo-a "$A_BASELINE_MARKER"
recover_rollout_baseline "$B_ROLLOUT" bookinfo-b "$B_BASELINE_MARKER"

TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh

for instance in bookinfo-a bookinfo-b; do
  stable_weight="$(oc get virtualservice.networking.istio.io "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
  canary_weight="$(oc get virtualservice.networking.istio.io "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
  [[ "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
    die "${instance} baseline routing is not fully restored: stable=${stable_weight:-missing}% canary=${canary_weight:-missing}%"

done

host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
host_b="$(oc get route bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
body_a="$(curl -sk "https://${host_a}/productpage" || true)"
body_b="$(curl -sk "https://${host_b}/productpage" || true)"
grep -q 'text-black-500' <<<"$body_a" || die "Bookinfo A baseline route is not healthy after recovery"
grep -q 'text-black-500' <<<"$body_b" || die "Bookinfo B baseline route is not healthy after recovery"

git fetch origin "$branch"
[[ "$(git rev-parse HEAD)" == "$revision" &&
   "$(git rev-parse "origin/${branch}")" == "$revision" ]] ||
  die "Git revision changed during recovery"

echo "==> Verified Bookinfo A Rollout parked at stable=100% canary=0%"
echo "==> Verified Bookinfo B Rollout baseline at stable=100% canary=0%"
echo "==> Verified Git source of truth: ${branch}@${revision:0:12}"

echo
oc argo rollouts get rollout "$A_ROLLOUT" -n "$NAMESPACE"
echo
oc argo rollouts get rollout "$B_ROLLOUT" -n "$NAMESPACE"
echo
echo "Multi-Bookinfo baseline is ready."
echo "Bookinfo A has its own Rollout and remains parked; only Bookinfo B is exercised by the demo scripts."
echo "Next: bash scripts/start-canary-mesh-multi-bookinfo.sh"
