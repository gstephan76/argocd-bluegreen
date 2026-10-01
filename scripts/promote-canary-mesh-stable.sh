#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-mesh-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-mesh-demo/rollout.yaml"
YELLOW_IMAGE="argoproj/rollouts-demo:yellow"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk sort tail cut; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
mesh_enable_failure_diagnostics
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

echo "==> Verifying OpenShift Service Mesh 3.4+ prerequisite"
bash scripts/check-canary-mesh-prereqs.sh

if ! git diff --quiet || ! git diff --cached --quiet; then die "Tracked Git changes exist"; fi
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

desired_revision="$(git rev-parse HEAD)"
desired_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"
desired_marker="$(awk -F'"' '/demo-rollout-revision:/ {print $2; exit}' "$ROLLOUT_FILE")"
[[ "$desired_image" == "$YELLOW_IMAGE" ]] || die "Git does not request the YELLOW candidate"
[[ "$desired_marker" == mesh-* && "$desired_marker" != "mesh-baseline-blue" ]] || die "Git does not contain a fresh Service Mesh canary marker"

sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
live_revision="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
[[ "$sync" == "Synced" && "$live_revision" == "$desired_revision" ]] || die "Argo CD must be Synced to current Git HEAD before promotion"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
rollout_revision="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' 2>/dev/null || true)"
current_image=""
[[ -z "$current" ]] || current_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${current}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
weights="$(oc get virtualservice rollouts-mesh-canary -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"

echo "Before promotion:"
printf '  phase=%s step=%s stable=%s current=%s image=%s marker=%s %s\n' "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}" "${current_image:-unknown}" "${live_marker:-unknown}" "${weights:-weights-unknown}"

[[ "$phase" == "Paused" && "$step" == "10" ]] || die "Rollout is not at the final manual approval pause (step 10)"
[[ -n "$current" ]] || die "Current canary ReplicaSet hash is empty"
[[ "$stable" != "$current" ]] || die "Current ReplicaSet is already stable"
[[ "$live_image" == "$desired_image" && "$live_marker" == "$desired_marker" ]] || die "Live Rollout desired state does not match Git"
[[ "$current_image" == "$YELLOW_IMAGE" ]] || die "Current candidate is not YELLOW"
[[ -n "$rollout_revision" ]] || die "Rollout revision is empty"

echo "==> Verifying the complete Service Mesh data plane before promotion"
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-dataplane.sh

analysis_for_step() {
  local wanted_step="$1"
  oc get analysisrun -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.rollout\.argoproj\.io/revision}{"|"}{.metadata.labels.rollouts-pod-template-hash}{"|"}{.metadata.labels.step-index}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"|"}{.status.phase}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null |
  awk -F'|' -v rev="$rollout_revision" -v hash="$current" -v step="$wanted_step" -v app="$APP_NAME" '$2 == rev && $3 == hash && $4 == step && $5 == "Rollout" && $6 == app && $7 == "Successful" { print $8 "|" $1 }' |
  sort | tail -1 | cut -d'|' -f2-
}

for analysis_step in 1 3 5 7 9; do
  analysis_name="$(analysis_for_step "$analysis_step")"
  [[ -n "$analysis_name" ]] || die "No Successful AnalysisRun is bound to the current candidate at step ${analysis_step}"
  echo "==> Verified step ${analysis_step} AnalysisRun: ${analysis_name}"
done

candidate_hash="$current"
echo "==> Promoting verified 100% YELLOW mesh canary to stable"
oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

echo "==> Waiting for the exact candidate hash to become stable"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  weights="$(oc get virtualservice rollouts-mesh-canary -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s %s\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${weights:-weights-unknown}"
  [[ "$phase" == "Degraded" ]] && die "Rollout became degraded during final promotion"
  if [[ "$phase" == "Healthy" && "$stable" == "$candidate_hash" && "$current" == "$candidate_hash" ]]; then break; fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for the mesh canary to become stable"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Final promotion complete: the verified YELLOW candidate is now stable."
