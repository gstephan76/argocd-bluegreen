#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc not found"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

latest="$(
  oc get analysisrun \
    -n "$NAMESPACE" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true
)"

[[ -n "$latest" ]] || die "No AnalysisRun found in namespace ${NAMESPACE}"

echo "Latest AnalysisRun: ${latest}"
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
