#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="bluegreen-demo/rollout.yaml"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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

active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
active_image=""
if [[ -n "$active_hash" ]]; then
  active_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${active_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
fi

desired_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"

if [[ "$desired_image" == "argoproj/rollouts-demo:blue" && "$active_image" == "argoproj/rollouts-demo:blue" ]]; then
  echo "BLUE is already the active baseline."
  exit 0
fi

case "$desired_image" in
  argoproj/rollouts-demo:green)
    echo "==> Changing Git desired image GREEN -> BLUE"
    sed -i 's#argoproj/rollouts-demo:green#argoproj/rollouts-demo:blue#' "$ROLLOUT_FILE"
    git add "$ROLLOUT_FILE"
    git diff --cached --check
    git commit -m "Restore blue baseline"
    git push origin "$branch"
    ;;
  argoproj/rollouts-demo:blue)
    echo "==> Git already requests BLUE"
    ;;
  *) die "Unexpected demo image: ${desired_image}" ;;
esac

revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  [[ "$sync" == "Synced" && "$got" == "$revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for BLUE preview and successful pre-promotion analysis"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_hash="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  pre_status="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.status}' 2>/dev/null || true)"
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  active_image=""
  [[ -z "$active_hash" ]] || active_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${active_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "$phase" == "Healthy" && "$active_hash" == "$preview_hash" && "$active_image" == "argoproj/rollouts-demo:blue" ]]; then
    echo "BLUE is already active and stable."
    exit 0
  fi
  preview_image=""
  [[ -z "$preview_hash" ]] || preview_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${preview_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  printf '    pre=%s active=%s preview=%s image=%s\n' "${pre_status:-pending}" "${active_hash:-none}" "${preview_hash:-none}" "${preview_image:-unknown}"
  case "$pre_status" in
    Successful)
      [[ "$preview_image" == "argoproj/rollouts-demo:blue" ]] && break
      ;;
    Failed|Error|Inconclusive) die "BLUE pre-promotion analysis ended with ${pre_status}" ;;
  esac
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for BLUE pre-promotion analysis"

echo "==> Promoting validated BLUE preview to establish the baseline"
exec bash scripts/promote-bluegreen.sh
