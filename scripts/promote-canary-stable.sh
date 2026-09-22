#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null || die "oc not found"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

phase="$(oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)"
step="$(oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

echo "Before promotion:"
printf '  phase=%s step=%s stable=%s current=%s\n' \
  "${phase:-unknown}" "${step:-unknown}" \
  "${stable:-none}" "${current:-none}"

[[ "$phase" == "Paused" ]] || \
  die "Rollout is not at the final manual approval pause"

[[ -n "$current" ]] || die "Current canary ReplicaSet hash is empty"
[[ "$stable" != "$current" ]] || die "Current ReplicaSet is already stable"

echo "==> Promoting validated 100% canary to stable"
oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

echo "==> Waiting for stableRS == currentPodHash"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"

  printf '    phase=%s stable=%s current=%s\n' \
    "${phase:-unknown}" "${stable:-none}" "${current:-none}"

  if [[ "$phase" == "Degraded" ]]; then
    die "Rollout became degraded during final promotion"
  fi

  if [[ "$phase" == "Healthy" &&
        -n "$stable" &&
        "$stable" == "$current" ]]; then
    break
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for the canary to become stable"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Final promotion complete: the validated canary ReplicaSet is now stable."
