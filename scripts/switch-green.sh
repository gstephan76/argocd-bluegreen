#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
PREVIEW_ONLY=false

case "${1:-}" in
  "") ;;
  --preview-only) PREVIEW_ONLY=true ;;
  *) echo "Usage: $0 [--preview-only]" >&2; exit 2 ;;
esac

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the argocd-bluegreen repository"
cd "$ROOT"

ROLLOUT_FILE="bluegreen-demo/rollout.yaml"
[[ -f "$ROLLOUT_FILE" ]] || die "$ROLLOUT_FILE not found"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts oc plugin is required"
[[ -z "$(git status --short --untracked-files=no)" ]] || die "Tracked Git changes exist"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local ${branch} must exactly match origin/${branch}"

current_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' "$ROLLOUT_FILE")"
case "$current_image" in
  argoproj/rollouts-demo:blue)
    echo "==> Changing Git desired image BLUE -> GREEN"
    sed -i 's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:green#' "$ROLLOUT_FILE"
    git add "$ROLLOUT_FILE"
    git diff --cached --check
    git commit -m "Deploy green preview"
    git push origin "$branch"
    ;;
  argoproj/rollouts-demo:green)
    echo "==> Git already requests GREEN"
    ;;
  *) die "Unexpected demo image: ${current_image}" ;;
esac

desired_revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  [[ "$sync" == "Synced" && "$got" == "$desired_revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD GREEN revision"

active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
active_image=""
[[ -z "$active_hash" ]] || active_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${active_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
if [[ "$active_image" == "argoproj/rollouts-demo:green" ]]; then
  echo "GREEN is already active. For a fresh demo first run: bash scripts/prepare-blue.sh"
  exit 0
fi

echo "==> Waiting for distinct GREEN preview ReplicaSet"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_hash="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_image=""
  [[ -z "$preview_hash" ]] || preview_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${preview_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  printf '    active=%s preview=%s image=%s\n' "${active_hash:-none}" "${preview_hash:-none}" "${preview_image:-unknown}"
  [[ -n "$active_hash" && -n "$preview_hash" && "$active_hash" != "$preview_hash" && "$preview_image" == "argoproj/rollouts-demo:green" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for GREEN preview"

echo "==> Waiting for GREEN preview pods Ready"
oc wait --for=condition=Ready pod -l "rollouts-pod-template-hash=${preview_hash}" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"

echo "==> Waiting for pre-promotion AnalysisRun"
deadline=$((SECONDS + TIMEOUT_SECONDS))
analysis_name=""
analysis_status=""
while (( SECONDS < deadline )); do
  analysis_name="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}' 2>/dev/null || true)"
  analysis_status="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.status}' 2>/dev/null || true)"
  printf '    analysis=%s status=%s\n' "${analysis_name:-pending}" "${analysis_status:-pending}"
  case "$analysis_status" in
    Successful) break ;;
    Failed|Error|Inconclusive)
      [[ -z "$analysis_name" ]] || oc get analysisrun "$analysis_name" -n "$NAMESPACE" -o yaml || true
      oc get job,pod -n "$NAMESPACE" -l app=bluegreen-demo-analysis -o wide || true
      die "Pre-promotion analysis ended with ${analysis_status}; production remains on BLUE"
      ;;
  esac
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for pre-promotion analysis"

active_host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"

echo
echo "GREEN preview validated."
echo "Production (BLUE): https://${active_host}"
echo "Preview (GREEN) : https://${preview_host}"
echo "Pre AnalysisRun : ${analysis_name}"
echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"

if [[ "$PREVIEW_ONLY" == "true" ]]; then
  echo
  echo "GREEN remains preview-only."
  echo "Next: bash scripts/promote-bluegreen.sh"
  echo "Direct equivalent: oc argo rollouts promote ${APP_NAME} -n ${NAMESPACE}"
  exit 0
fi

echo
echo "==> Continuing with production promotion and post-promotion validation"
exec bash scripts/promote-bluegreen.sh
