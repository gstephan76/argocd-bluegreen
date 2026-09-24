#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
APP_NAME="${APP_NAME:-metric-ai-demo}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc awk sort tail cut; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

rollout_revision="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
    2>/dev/null || true
)"
current_hash="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.currentPodHash}' \
    2>/dev/null || true
)"

[[ -n "$rollout_revision" ]] || \
  die "Rollout ${NAMESPACE}/${APP_NAME} has no rollout revision annotation"
[[ -n "$current_hash" ]] || \
  die "Rollout ${NAMESPACE}/${APP_NAME} has no currentPodHash"

latest="$(
  oc get analysisrun \
    -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.rollout\.argoproj\.io/revision}{"|"}{.metadata.labels.rollouts-pod-template-hash}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' \
    2>/dev/null |
  awk -F'|' \
    -v rev="$rollout_revision" \
    -v hash="$current_hash" \
    -v app="$APP_NAME" \
    '$2 == rev && $3 == hash && $4 == "Rollout" && $5 == app { print $6 "|" $1 }' |
  sort |
  tail -1 |
  cut -d'|' -f2-
)"

[[ -n "$latest" ]] || \
  die "No AnalysisRun belongs to current rollout revision=${rollout_revision} hash=${current_hash}"

echo "Current Rollout AnalysisRun: ${latest}"
echo "Rollout revision: ${rollout_revision}"
echo "Current hash:     ${current_hash}"
echo

oc get analysisrun "$latest" \
  -n "$NAMESPACE" \
  -o jsonpath='phase={.status.phase}{"\n"}'

echo
oc get analysisrun "$latest" \
  -n "$NAMESPACE" \
  -o jsonpath='{range .status.metricResults[*]}metric={.name} phase={.phase} successful={.successful} failed={.failed}{"\n"}{range .measurements[*]}  value={.value} measurementPhase={.phase}{"\n"}  confidence={.metadata.confidence}{"\n"}  analysis={.metadata.analysis}{"\n\n"}{end}{end}'

echo
echo "Full AnalysisRun:"
oc get analysisrun "$latest" \
  -n "$NAMESPACE" \
  -o yaml
