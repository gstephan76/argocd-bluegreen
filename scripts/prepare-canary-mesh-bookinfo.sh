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

if ! git diff --quiet || ! git diff --cached --quiet; then die "Tracked Git changes exist"; fi
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

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
  git commit -m "Restore whole-Bookinfo canary baseline"
  git push origin "$branch"
fi
revision="$(git rev-parse HEAD)"

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
  printf '    phase=%s stable=%s current=%s marker=%s\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${marker:-missing}"

  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" &&
        "$marker" == "$BASELINE_MARKER" &&
        "$details" == "bookinfo-details-stable" &&
        "$reviews" == "bookinfo-reviews-stable" &&
        "$ratings" == "bookinfo-ratings-stable" ]]; then
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

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Stable whole-Bookinfo baseline is ready."
echo "Next: bash scripts/start-canary-mesh-bookinfo.sh"
