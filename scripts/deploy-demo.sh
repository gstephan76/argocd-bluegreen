#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUT_MANAGER_NAMESPACE="${ROLLOUT_MANAGER_NAMESPACE:-openshift-gitops}"
ANALYSIS_TEMPLATE="${ANALYSIS_TEMPLATE:-bluegreen-demo-smoke-test}"
POST_ANALYSIS_TEMPLATE="${POST_ANALYSIS_TEMPLATE:-bluegreen-demo-post-smoke-test}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

need oc
need git

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the argocd-bluegreen repository."
cd "$ROOT"

for f in \
  bootstrap/kustomization.yaml \
  argocd/application.yaml \
  bluegreen-demo/rollout.yaml \
  bluegreen-demo/analysis-template.yaml \
  bluegreen-demo/post-analysis-template.yaml
do
  [[ -f "$f" ]] || die "$f not found"
done

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift."

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported."
[[ -z "$(git status --short --untracked-files=no)" ]] || \
  die "Tracked Git changes exist. Commit/stash them before deploying."

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local ${branch} must exactly match origin/${branch}."

desired_revision="$(git rev-parse HEAD)"
desired_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' bluegreen-demo/rollout.yaml)"
[[ -n "$desired_image" ]] || die "Could not determine desired image."

echo "==> Git revision: ${desired_revision}"
echo "==> Desired image: ${desired_image}"

echo "==> Verifying required CRDs"
for crd in \
  applications.argoproj.io \
  argocds.argoproj.io \
  rollouts.argoproj.io \
  rolloutmanagers.argoproj.io \
  analysistemplates.argoproj.io \
  analysisruns.argoproj.io
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done

echo "==> Applying Rollouts bootstrap"
oc apply -k bootstrap

echo "==> Waiting for RolloutManager ${ROLLOUT_MANAGER}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rolloutmanager "$ROLLOUT_MANAGER" -n "$ROLLOUT_MANAGER_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  controller="$(oc get rolloutmanager "$ROLLOUT_MANAGER" -n "$ROLLOUT_MANAGER_NAMESPACE" -o jsonpath='{.status.rolloutController}' 2>/dev/null || true)"
  printf '    phase=%s controller=%s\n' "${phase:-unknown}" "${controller:-unknown}"
  [[ "$phase" == "Available" || "$controller" == "Available" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for RolloutManager."

echo "==> Applying Argo CD Application"
oc apply -f argocd/application.yaml
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  revision="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  printf '    sync=%s health=%s revision=%s\n' "${sync:-unknown}" "${health:-unknown}" "${revision:0:12}"
  [[ "$sync" == "Synced" && "$revision" == "$desired_revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD revision ${desired_revision}."

for template in "$ANALYSIS_TEMPLATE" "$POST_ANALYSIS_TEMPLATE"; do
  echo "==> Waiting for AnalysisTemplate ${template}"
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    oc get analysistemplate "$template" -n "$NAMESPACE" >/dev/null 2>&1 && break
    sleep "$POLL_SECONDS"
  done
  (( SECONDS < deadline )) || die "Timed out waiting for AnalysisTemplate ${template}."
done

echo "==> Waiting for Rollout"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  oc get rollout "$APP_NAME" -n "$NAMESPACE" >/dev/null 2>&1 && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Rollout ${APP_NAME}."

echo "==> Waiting for application pods to become Ready"
oc wait --for=condition=Ready pod \
  -l app="$APP_NAME" \
  -n "$NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s"

active_host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"

echo
echo "==> Current Blue/Green state"
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" 2>/dev/null || \
  oc get rollout "$APP_NAME" -n "$NAMESPACE"

echo
echo "Active URL : https://${active_host}"
echo "Preview URL: https://${preview_host}"
echo "PRE analysis : ${ANALYSIS_TEMPLATE}"
echo "POST analysis: ${POST_ANALYSIS_TEMPLATE}"
echo
case "$desired_image" in
  argoproj/rollouts-demo:blue)
    echo "Next: bash scripts/switch-green.sh --preview-only"
    ;;
  argoproj/rollouts-demo:green)
    echo "For a clean BLUE -> GREEN replay: bash scripts/prepare-blue.sh"
    ;;
  *)
    echo "Unexpected demo image in Git: ${desired_image}"
    ;;
esac
