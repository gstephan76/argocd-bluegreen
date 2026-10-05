#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-mesh-bookinfo/rollout.yaml"
BASELINE_MARKER="bookinfo-baseline-stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed grep; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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

echo "==> Verifying Git repository state"
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"

# Never auto-commit arbitrary user work. prepare owns only the baseline mutation
# it performs below. Existing tracked working-tree/index changes must be handled
# explicitly by the operator before recovery begins.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Tracked Git changes:" >&2
  git status --short --untracked-files=no >&2 || true
  die "Tracked Git changes exist; commit or restore them before running prepare"
fi

git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) ||
  die "Local ${branch} is ${behind} commit(s) behind origin/${branch}; update/reconcile it before running prepare"

# A clean local branch may legitimately contain commits not pushed yet. Push
# those first so the recovery commit is based on the same history Argo CD sees.
if (( ahead > 0 )); then
  echo "==> Local ${branch} is ${ahead} commit(s) ahead of origin/${branch}; pushing"
  git push origin "$branch"
fi

git fetch origin "$branch"
local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/${branch}")"
[[ "$local_head" == "$remote_head" ]] ||
  die "Git state is not synchronized after preflight: HEAD=${local_head} origin/${branch}=${remote_head}"
echo "==> Git preflight synchronized at ${local_head:0:12}"

echo "==> Restoring the stable whole-Bookinfo productpage baseline in Git"
sed -i -E 's#demo-bookinfo-revision: ".*"#demo-bookinfo-revision: "bookinfo-baseline-stable"#' "$ROLLOUT_FILE"
sed -i -E 's#track: (stable|canary)#track: stable#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-details-(stable|canary)#value: bookinfo-details-stable#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-reviews-(stable|canary)#value: bookinfo-reviews-stable#' "$ROLLOUT_FILE"
sed -i -E 's#value: bookinfo-ratings-(stable|canary)#value: bookinfo-ratings-stable#' "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already declares the stable whole-Bookinfo baseline"
else
  echo "==> Committing stable whole-Bookinfo baseline"
  git commit -m "Restore whole-Bookinfo canary baseline"
fi

# Push whenever prepare created a commit or a clean local commit became pending.
# Refuse to merge/rebase automatically if the remote moved while prepare ran.
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 )) ||
  die "origin/${branch} advanced during prepare; refusing automatic merge/rebase"
if (( ahead > 0 )); then
  echo "==> Pushing ${ahead} recovery commit(s) to origin/${branch}"
  git push origin "$branch"
fi

git fetch origin "$branch"
revision="$(git rev-parse HEAD)"
remote_head="$(git rev-parse "origin/${branch}")"
[[ "$revision" == "$remote_head" ]] ||
  die "Push verification failed: HEAD=${revision} origin/${branch}=${remote_head}"
git diff --quiet && git diff --cached --quiet ||
  die "Tracked Git changes remain after baseline commit/push"
echo "==> Git baseline committed/pushed and verified at ${revision:0:12}"

if ! oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  bash scripts/deploy-canary-mesh-bookinfo.sh
else
  oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
fi

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
  die "Argo CD did not reconcile exact revision ${revision}"

echo "==> Recovering the trusted stable baseline"
deadline=$((SECONDS + TIMEOUT_SECONDS))
promotion_requested=0
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  details="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
  reviews="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
  ratings="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
  stable_weight="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
  canary_weight="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s marker=%s routing=stable:%s%%/canary:%s%%\n' \
    "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${marker:-missing}" \
    "${stable_weight:-unknown}" "${canary_weight:-unknown}"

  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" &&
        "$marker" == "$BASELINE_MARKER" &&
        "$details" == "bookinfo-details-stable" &&
        "$reviews" == "bookinfo-reviews-stable" &&
        "$ratings" == "bookinfo-ratings-stable" &&
        "$stable_weight" == "100" && "$canary_weight" == "0" ]]; then
    break
  fi

  if [[ "$marker" == "$BASELINE_MARKER" && -n "$current" && "$stable" != "$current" && "$promotion_requested" == "0" ]]; then
    echo "==> Fully promoting verified baseline recovery"
    oc argo rollouts promote --full "$APP_NAME" -n "$NAMESPACE"
    promotion_requested=1
  fi
  [[ "$phase" != "Degraded" ]] || die "Baseline recovery became Degraded"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring stable whole-Bookinfo baseline"

TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-bookinfo-dataplane.sh

# Final independent read: prepare must never print success if Rollouts/Argo CD
# left or subsequently changed the runtime routing away from the baseline.
stable_weight="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
canary_weight="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
[[ "$stable_weight" == "100" && "$canary_weight" == "0" ]] ||
  die "Baseline routing is not fully restored: expected stable=100% canary=0%, got stable=${stable_weight:-missing}% canary=${canary_weight:-missing}%"

# Also prove the local Git commit used by Argo CD is still exactly the verified
# remote revision after all recovery actions.
git fetch origin "$branch"
[[ "$(git rev-parse HEAD)" == "$revision" &&
   "$(git rev-parse "origin/${branch}")" == "$revision" ]] ||
  die "Git revision changed during recovery; refusing to report a verified baseline"

echo "==> Verified baseline Istio routing: stable=100% canary=0%"
echo "==> Verified Git source of truth: ${branch}@${revision:0:12}"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Stable whole-Bookinfo baseline is ready."
echo "Next: bash scripts/start-canary-mesh-bookinfo.sh"
