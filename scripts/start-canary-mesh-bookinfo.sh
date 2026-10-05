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
for c in oc git sed grep jq date head; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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

candidate_spec_in_git() {
  grep -q 'demo-bookinfo-revision: "bookinfo-candidate-' "$ROLLOUT_FILE" &&
  grep -q 'track: canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-details-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-reviews-canary' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-ratings-canary' "$ROLLOUT_FILE"
}

baseline_spec_in_git() {
  grep -q 'demo-bookinfo-revision: "bookinfo-baseline-stable"' "$ROLLOUT_FILE" &&
  grep -q 'track: stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-details-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-reviews-stable' "$ROLLOUT_FILE" &&
  grep -q 'value: bookinfo-ratings-stable' "$ROLLOUT_FILE"
}

marker="$(sed -n -E 's/^[[:space:]]*demo-bookinfo-revision:[[:space:]]*"([^"]+)".*/\1/p' "$ROLLOUT_FILE" | head -1)"
revision="$(git rev-parse HEAD)"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"

if [[ "$marker" == bookinfo-candidate-* ]]; then
  candidate_spec_in_git || die "Git candidate marker exists but the candidate downstream targets are incomplete"
  echo "==> Existing candidate ${marker} already declared in Git; resuming it idempotently"

  # A repeated start after promotion must not manufacture a second candidate.
  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$marker" ]]; then
    details="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="DETAILS_HOSTNAME")].value}' 2>/dev/null || true)"
    reviews="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="REVIEWS_HOSTNAME")].value}' 2>/dev/null || true)"
    ratings="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="RATINGS_HOSTNAME")].value}' 2>/dev/null || true)"
    [[ "$details" == "bookinfo-details-canary" && "$reviews" == "bookinfo-reviews-canary" && "$ratings" == "bookinfo-ratings-canary" ]] ||
      die "Promoted candidate is not isolated to the canary downstream stack"
    TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-bookinfo-dataplane.sh
    echo "==> Candidate ${marker} is already promoted; start is already satisfied"
    echo "Run scripts/prepare-canary-mesh-bookinfo.sh before beginning a new candidate cycle."
    exit 0
  fi
else
  [[ "$marker" == "$BASELINE_MARKER" ]] || die "Unexpected Git rollout marker: ${marker:-missing}"
  baseline_spec_in_git || die "Git baseline marker exists but stable downstream targets are incomplete"
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
  if git diff --cached --quiet; then
    die "Candidate mutation produced no Git change from a verified baseline"
  fi
  git commit -m "Start whole-Bookinfo canary ${marker}"

  git fetch origin "$branch"
  read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
  (( behind == 0 )) || die "origin/${branch} advanced while declaring the candidate"
  (( ahead > 0 )) && git push origin "$branch"
  git fetch origin "$branch"
  revision="$(git rev-parse HEAD)"
  [[ "$revision" == "$(git rev-parse "origin/${branch}")" ]] || die "Candidate push verification failed"
fi

# Re-running after an interrupted push lands here and reuses the same candidate
# commit instead of generating another timestamped revision.
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
  live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-bookinfo-revision}' 2>/dev/null || true)"
  weights="$(oc get virtualservice "$APP_NAME" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"
  printf '    phase=%s step=%s stable=%s current=%s marker=%s %s\n' "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}" "${live_marker:-missing}" "${weights:-weights-unknown}"
  [[ "$phase" != "Degraded" ]] || die "Whole-Bookinfo canary became Degraded"

  # Promotion may have completed between two idempotent invocations.
  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_marker" == "$marker" ]]; then
    echo "==> Candidate ${marker} is already promoted; start is already satisfied"
    exit 0
  fi

  [[ "$phase" == "Paused" && "$step" == "10" && -n "$current" && "$stable" != "$current" && "$live_marker" == "$marker" ]] && break
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
echo "Repeated start invocations will reuse candidate ${marker}; they will not create another revision."
echo "Sample it with: REQUESTS=200 bash scripts/sample-canary-mesh-bookinfo.sh"
echo "Promote with: bash scripts/promote-canary-mesh-bookinfo.sh"
