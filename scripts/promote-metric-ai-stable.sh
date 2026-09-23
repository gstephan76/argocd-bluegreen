#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc not found"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

printf 'Before promotion: phase=%s step=%s stable=%s current=%s\n' \
  "${phase:-unknown}" "${step:-unknown}" "${stable:-none}" "${current:-none}"

[[ "$phase" == "Paused" && "$step" == "4" ]] || \
  die "Rollout is not at the AI-approved final pause"
[[ -n "$current" ]] || die "Current canary hash is empty"
[[ "$stable" != "$current" ]] || die "Current ReplicaSet is already stable"

echo "==> Promoting AI-approved candidate"
oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

  printf '    phase=%s stable=%s current=%s\n' \
    "${phase:-unknown}" "${stable:-none}" "${current:-none}"

  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]] && break
  [[ "$phase" == "Degraded" ]] && die "Rollout degraded during final promotion"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for candidate to become stable"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "AI-approved candidate is now stable."
