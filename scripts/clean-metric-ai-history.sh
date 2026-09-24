#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-3}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc awk; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

[[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]] || \
  die "clean-history requires a settled Healthy rollout; run reset first"

echo "==> Deleting completed AI AnalysisRun history"
oc delete analysisrun \
  -n "$NAMESPACE" \
  --all \
  --ignore-not-found

echo "==> Restarting AI agent to clear its in-memory activity-event store"
oc rollout restart deployment/"$AGENT_NAME" \
  -n "$ARGOCD_NAMESPACE" >/dev/null
oc rollout status deployment/"$AGENT_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s" >/dev/null

desired="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || true
)"
[[ "$desired" =~ ^[0-9]+$ && "$desired" -gt 0 ]] || \
  die "Could not determine desired application replica count"

ready_count() {
  oc get pods \
    -n "$NAMESPACE" \
    -l "app=${APP_NAME}" \
    -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
    2>/dev/null |
  awk '$0 == "True" { n++ } END { print n+0 }'
}

pod_count() {
  oc get pods \
    -n "$NAMESPACE" \
    -l "app=${APP_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null |
  awk 'NF { n++ } END { print n+0 }'
}

wait_for_replicas() {
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    total="$(pod_count)"
    ready="$(ready_count)"
    printf '    application pods total=%s ready=%s desired=%s\n' \
      "$total" "$ready" "$desired"
    if (( total >= desired && ready >= desired )); then
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  return 1
}

echo "==> Recycling dashboard/application pods one at a time"
mapfile -t original_pods < <(
  oc get pods \
    -n "$NAMESPACE" \
    -l "app=${APP_NAME}" \
    --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

for pod in "${original_pods[@]}"; do
  [[ -n "$pod" ]] || continue
  echo "    recycling ${pod}"
  oc delete pod "$pod" \
    -n "$NAMESPACE" \
    --wait=false >/dev/null
  wait_for_replicas || \
    die "Timed out waiting for application replicas after recycling ${pod}"
done

host="$(
  oc get route "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true
)"

echo
echo "AI progressive-delivery history cleared."
echo "AnalysisRuns, AI-agent activity memory, and dashboard pod caches were reset."
if [[ -n "$host" ]]; then
  echo "Refresh the browser to clear browser-local graph history:"
  echo "  https://${host}/"
fi
