#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="metric-ai-demo/app/rollout.yaml"
HEALTHY_IMAGE="ghcr.io/kdubois/argo-rollouts-quarkus-demo:v1.stable"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk sort tail cut; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

desired_revision="$(git rev-parse HEAD)"
desired_image="$(
  awk '/^[[:space:]]*image:[[:space:]]+ghcr.io\/kdubois\/argo-rollouts-quarkus-demo:/ {print $2; exit}' \
    "$ROLLOUT_FILE"
)"
desired_marker="$(
  awk -F'"' '/demo-rollout-revision:/ {print $2; exit}' "$ROLLOUT_FILE"
)"
desired_template="$(
  awk '/templateName:[[:space:]]+metric-ai-analysis/ {print $2; exit}' "$ROLLOUT_FILE"
)"

[[ "$desired_image" == "$HEALTHY_IMAGE" ]] || \
  die "Git does not request the healthy v1.stable candidate"
[[ "$desired_marker" == ai-healthy-* ]] || \
  die "Git does not contain a fresh healthy scenario marker"
[[ "$desired_template" == "metric-ai-analysis" ]] || \
  die "Healthy promotion requires the normal metric-ai-analysis template"

sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
live_revision="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
[[ "$sync" == "Synced" && "$live_revision" == "$desired_revision" ]] || \
  die "Argo CD must be Synced to current Git HEAD before promotion"

live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
live_template="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.strategy.canary.steps[2].analysis.templates[0].templateName}' 2>/dev/null || true)"
[[ "$live_image" == "$desired_image" ]] || die "Live Rollout image does not match Git"
[[ "$live_marker" == "$desired_marker" ]] || die "Live Rollout marker does not match Git"
[[ "$live_template" == "$desired_template" ]] || die "Live AnalysisTemplate does not match Git"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
rollout_revision="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' 2>/dev/null || true)"
current_image=""
[[ -z "$current" ]] || current_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${current}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"

printf 'Before promotion: phase=%s step=%s stable=%s current=%s\n' \
  "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}"

[[ "$phase" == "Paused" && "$step" == "4" ]] || \
  die "Rollout is not at the AI-approved final pause"
[[ -n "$current" ]] || die "Current canary hash is empty"
[[ "$stable" != "$current" ]] || die "Current ReplicaSet is already stable"
[[ "$current_image" == "$HEALTHY_IMAGE" ]] || die "Current candidate is not v1.stable"
[[ -n "$rollout_revision" ]] || die "Current Rollout revision is empty"

analysis_name="$(
  oc get analysisrun \
    -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.rollout\.argoproj\.io/revision}{"|"}{.metadata.labels.rollouts-pod-template-hash}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' \
    2>/dev/null |
  awk -F'|' \
    -v rev="$rollout_revision" \
    -v hash="$current" \
    -v app="$APP_NAME" \
    '$2 == rev && $3 == hash && $4 == "Rollout" && $5 == app { print $6 "|" $1 }' |
  sort |
  tail -1 |
  cut -d'|' -f2-
)"
[[ -n "$analysis_name" ]] || \
  die "No AnalysisRun is bound to the current healthy candidate"

analysis_phase="$(oc get analysisrun "$analysis_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
[[ "$analysis_phase" == "Successful" ]] || \
  die "Current candidate AnalysisRun ${analysis_name} is ${analysis_phase:-unknown}, not Successful"

candidate_hash="$current"
echo "==> Verified AnalysisRun ${analysis_name} for current Git-bound candidate"

echo "==> Promoting AI-approved candidate"
oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

  printf '    phase=%s stable=%s current=%s\n' \
    "${phase:-unknown}" "${stable:-none}" "${current:-none}"

  [[ "$phase" == "Healthy" &&
     "$stable" == "$candidate_hash" &&
     "$current" == "$candidate_hash" ]] && break
  [[ "$phase" == "Degraded" ]] && die "Rollout degraded during final promotion"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for candidate to become stable"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "AI-approved candidate is now stable."
