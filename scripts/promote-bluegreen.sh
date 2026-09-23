#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc not found"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts oc plugin is required"

active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
preview_hash="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
pre_name="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}' 2>/dev/null || true)"
pre_status="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.status}' 2>/dev/null || true)"

active_host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"

echo "Current state:"
printf '  phase=%s\n  active=%s\n  preview=%s\n  stable=%s\n  pre-analysis=%s (%s)\n' \
  "${phase:-unknown}" "${active_hash:-none}" "${preview_hash:-none}" \
  "${stable_hash:-none}" "${pre_name:-none}" "${pre_status:-none}"
echo "  Active URL : https://${active_host}"
echo "  Preview URL: https://${preview_host}"

if [[ "$phase" == "Healthy" && -n "$active_hash" && "$active_hash" == "$preview_hash" && "$active_hash" == "$stable_hash" ]]; then
  echo "Preview is already fully promoted and stable."
  exit 0
fi

[[ -n "$active_hash" ]] || die "Active Service has no Rollouts hash selector"
[[ -n "$preview_hash" ]] || die "Preview Service has no Rollouts hash selector"
previous_stable_hash="$stable_hash"
[[ -n "$previous_stable_hash" ]] || previous_stable_hash="$active_hash"

if [[ "$active_hash" != "$preview_hash" ]]; then
  [[ "$pre_status" == "Successful" ]] || die "Pre-promotion analysis is not Successful"
  [[ "$phase" == "Paused" ]] || die "Rollout is not paused at the manual promotion gate"

  echo "==> Promoting validated preview to ACTIVE"
  oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE"

  echo "==> Waiting for ACTIVE Service selector switch"
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
    printf '    active=%s expected=%s\n' "${active_hash:-none}" "$preview_hash"
    [[ "$active_hash" == "$preview_hash" ]] && break
    sleep "$POLL_SECONDS"
  done
  (( SECONDS < deadline )) || die "Timed out waiting for ACTIVE Service switch"
else
  echo "ACTIVE already points at the preview hash; continuing with post-promotion validation."
fi

echo "==> Waiting for post-promotion AnalysisRun"
deadline=$((SECONDS + TIMEOUT_SECONDS))
post_name=""
post_status=""
while (( SECONDS < deadline )); do
  post_name="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.postPromotionAnalysisRunStatus.name}' 2>/dev/null || true)"
  post_status="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.postPromotionAnalysisRunStatus.status}' 2>/dev/null || true)"
  printf '    post-analysis=%s status=%s\n' "${post_name:-pending}" "${post_status:-pending}"

  case "$post_status" in
    Successful) break ;;
    Failed|Error|Inconclusive)
      [[ -z "$post_name" ]] || oc get analysisrun "$post_name" -n "$NAMESPACE" -o yaml || true
      oc get job,pod -n "$NAMESPACE" -l app=bluegreen-demo-post-analysis -o wide || true
      echo "==> Waiting for automatic rollback to previous stable hash ${previous_stable_hash}"
      rollback_deadline=$((SECONDS + TIMEOUT_SECONDS))
      while (( SECONDS < rollback_deadline )); do
        active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
        [[ -n "$previous_stable_hash" && "$active_hash" == "$previous_stable_hash" ]] && break
        sleep "$POLL_SECONDS"
      done
      oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
      die "Post-promotion analysis ended with ${post_status}; rollout aborted"
      ;;
  esac
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for post-promotion analysis"

echo "==> Waiting for promoted ReplicaSet to become stable"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s active=%s\n' "${phase:-unknown}" "${stable_hash:-none}" "${active_hash:-none}"
  [[ "$phase" == "Healthy" && "$stable_hash" == "$preview_hash" && "$active_hash" == "$preview_hash" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Candidate did not become stable before timeout"

echo
echo "Promotion complete."
echo "Active URL : https://${active_host}"
echo "Preview URL: https://${preview_host}"
echo "Post AnalysisRun: ${post_name}"
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
