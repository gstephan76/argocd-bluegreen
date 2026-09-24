#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="bluegreen-demo/rollout.yaml"
GREEN_IMAGE="argoproj/rollouts-demo:green"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk rg; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the argocd-bluegreen repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts oc plugin is required"
[[ -z "$(git status --short --untracked-files=no)" ]] || die "Tracked Git changes exist"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local ${branch} must exactly match origin/${branch}"

desired_revision="$(git rev-parse HEAD)"
desired_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"
desired_marker="$(awk -F'"' '/demo-rollout-revision:/ {print $2; exit}' "$ROLLOUT_FILE")"
expected_green_count="$(
  awk '
    /- name: expected-color/ {
      getline
      if ($1 == "value:" && $2 == "green") n++
    }
    END { print n+0 }
  ' "$ROLLOUT_FILE"
)"

[[ "$desired_image" == "$GREEN_IMAGE" ]] || \
  die "Git does not request GREEN; run switch-green.sh --preview-only first"
[[ "$desired_marker" == bluegreen-green-* ]] || \
  die "Git does not contain a fresh GREEN rollout marker"
[[ "$expected_green_count" == "2" ]] || \
  die "Both pre/post analyses must expect GREEN"

sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
live_revision="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
[[ "$sync" == "Synced" && "$live_revision" == "$desired_revision" ]] || \
  die "Argo CD must be Synced to current Git HEAD before promotion"

live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
[[ "$live_image" == "$desired_image" ]] || die "Live Rollout image does not match Git"
[[ "$live_marker" == "$desired_marker" ]] || die "Live Rollout marker does not match Git"

active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
preview_hash="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
pre_name="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}' 2>/dev/null || true)"
pre_status="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.status}' 2>/dev/null || true)"
active_image=""
preview_image=""
[[ -z "$active_hash" ]] || active_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${active_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
[[ -z "$preview_hash" ]] || preview_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${preview_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"

active_host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"

echo "Current state:"
printf '  phase=%s\n  active=%s\n  preview=%s\n  stable=%s\n  current=%s\n  pre-analysis=%s (%s)\n' \
  "${phase:-unknown}" "${active_hash:-none}" "${preview_hash:-none}" \
  "${stable_hash:-none}" "${current_hash:-none}" "${pre_name:-none}" "${pre_status:-none}"
echo "  Active URL : https://${active_host}"
echo "  Preview URL: https://${preview_host}"

if [[ "$phase" == "Healthy" &&
      -n "$stable_hash" &&
      "$active_hash" == "$stable_hash" &&
      "$preview_hash" == "$stable_hash" &&
      "$current_hash" == "$stable_hash" &&
      "$active_image" == "$GREEN_IMAGE" ]]; then
  echo "GREEN is already fully promoted and stable."
  exit 0
fi

[[ -n "$stable_hash" ]] || die "Rollout has no stableRS; refusing promotion"
[[ "$active_hash" == "$stable_hash" ]] || \
  die "ACTIVE Service is not bound to stableRS; refusing promotion"
[[ -n "$preview_hash" && "$preview_hash" != "$active_hash" ]] || \
  die "Preview is not a distinct candidate"
[[ "$preview_hash" == "$current_hash" ]] || \
  die "Preview hash is not the current desired ReplicaSet"
[[ "$preview_image" == "$GREEN_IMAGE" ]] || \
  die "Preview ReplicaSet is not GREEN"
[[ "$pre_status" == "Successful" ]] || die "Pre-promotion analysis is not Successful"
[[ "$phase" == "Paused" ]] || die "Rollout is not paused at the manual promotion gate"

previous_stable_hash="$stable_hash"

echo "==> Promoting Git-bound validated GREEN preview to ACTIVE"
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
        [[ "$active_hash" == "$previous_stable_hash" ]] && break
        sleep "$POLL_SECONDS"
      done

      if [[ "$active_hash" != "$previous_stable_hash" ]]; then
        oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
        die "Post-analysis failed and ACTIVE did not return to previous stable ReplicaSet"
      fi

      oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
      die "Post-promotion analysis ended with ${post_status}; rollback to previous stable ReplicaSet confirmed"
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
  current_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_hash_now="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s active=%s preview=%s\n' \
    "${phase:-unknown}" "${stable_hash:-none}" "${current_hash:-none}" \
    "${active_hash:-none}" "${preview_hash_now:-none}"
  [[ "$phase" == "Healthy" &&
     "$stable_hash" == "$preview_hash" &&
     "$current_hash" == "$preview_hash" &&
     "$active_hash" == "$preview_hash" &&
     "$preview_hash_now" == "$preview_hash" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Candidate did not become stable before timeout"

echo
echo "Promotion complete."
echo "Active URL : https://${active_host}"
echo "Preview URL: https://${preview_host}"
echo "Post AnalysisRun: ${post_name}"
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
