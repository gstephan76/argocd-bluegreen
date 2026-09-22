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

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

app_revision() {
  oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
}

wait_for_analysis_template() {
  local template_name="$1"
  local stage="$2"
  local deadline
  local current_revision

  echo "==> Verifying the ${stage} AnalysisTemplate"
  deadline=$((SECONDS + TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if oc get analysistemplate "${template_name}" \
      -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo "    AnalysisTemplate ${template_name} is present."
      return 0
    fi

    current_revision="$(app_revision)"
    printf '    waiting for %s; Argo CD revision=%s\n' \
      "${template_name}" "${current_revision:0:12}"

    sleep "${POLL_SECONDS}"
  done

  oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" -o yaml || true
  die "Timed out waiting for AnalysisTemplate ${template_name}."
}

need oc
need git

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${REPO_ROOT}" ]] || die "Run this script from inside the argocd-bluegreen Git repository."
cd "${REPO_ROOT}"

[[ -f bootstrap/kustomization.yaml ]] || die "bootstrap/kustomization.yaml not found."
[[ -f argocd/application.yaml ]] || die "argocd/application.yaml not found."
[[ -f bluegreen-demo/rollout.yaml ]] || die "bluegreen-demo/rollout.yaml not found."
[[ -f bluegreen-demo/analysis-template.yaml ]] || die "bluegreen-demo/analysis-template.yaml not found."
[[ -f bluegreen-demo/post-analysis-template.yaml ]] || die "bluegreen-demo/post-analysis-template.yaml not found."

oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster. Run 'oc login' first."

branch="$(git branch --show-current)"
[[ -n "${branch}" ]] || die "Detached HEAD is not supported."
git remote get-url origin >/dev/null 2>&1 || die "Git remote 'origin' is not configured."

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes are present. Commit/stash them before deploying so local manifests and GitOps desired state cannot diverge."
fi

echo "==> Refreshing origin/${branch}"
git fetch origin

if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
  read -r behind ahead < <(
    git rev-list --left-right --count "origin/${branch}...HEAD"
  )

  if (( behind > 0 )); then
    die "Local ${branch} is behind origin/${branch} by ${behind} commit(s). Run: git pull --ff-only"
  fi

  if (( ahead > 0 )); then
    die "Local ${branch} is ahead of origin/${branch} by ${ahead} commit(s). Push first."
  fi
fi

desired_revision="$(git rev-parse HEAD)"
desired_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' \
  bluegreen-demo/rollout.yaml)"

[[ -n "${desired_image}" ]] || \
  die "Could not determine desired image from bluegreen-demo/rollout.yaml."

echo "==> Target Git revision: ${desired_revision}"
echo "==> Desired image: ${desired_image}"

echo "==> Verifying required CRDs"
for crd in \
  applications.argoproj.io \
  rollouts.argoproj.io \
  rolloutmanagers.argoproj.io \
  analysistemplates.argoproj.io \
  analysisruns.argoproj.io
do
  oc get crd "${crd}" >/dev/null 2>&1 || die "Missing CRD: ${crd}"
done

repo_url="$(awk '/^[[:space:]]*repoURL:/ {print $2; exit}' argocd/application.yaml)"
[[ -n "${repo_url}" ]] || die "repoURL not found in argocd/application.yaml"
[[ "${repo_url}" != *REPLACE_ME* ]] || die "argocd/application.yaml still contains a REPLACE_ME repoURL."

echo "==> Applying RolloutManager / Argo CD bootstrap"
oc apply -k bootstrap

echo "==> Waiting for RolloutManager ${ROLLOUT_MANAGER} to become available"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rolloutmanager "${ROLLOUT_MANAGER}" \
    -n "${ROLLOUT_MANAGER_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  controller="$(oc get rolloutmanager "${ROLLOUT_MANAGER}" \
    -n "${ROLLOUT_MANAGER_NAMESPACE}" \
    -o jsonpath='{.status.rolloutController}' 2>/dev/null || true)"

  if [[ "${phase}" == "Available" || "${controller}" == "Available" ]]; then
    echo "    RolloutManager is available."
    break
  fi

  printf '    phase=%s controller=%s\n' \
    "${phase:-unknown}" \
    "${controller:-unknown}"

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get rolloutmanager "${ROLLOUT_MANAGER}" -n "${ROLLOUT_MANAGER_NAMESPACE}" -o yaml || true
  die "Timed out waiting for RolloutManager."
fi

echo "==> Creating/updating the Argo CD Application"
oc apply -f argocd/application.yaml

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "${APP_NAME}" \
  -n "${ARGOCD_NAMESPACE}" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD Application ${APP_NAME} to sync ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync_status="$(oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  synced_revision="$(app_revision)"

  printf '    sync=%s health=%s revision=%s\n' \
    "${sync_status:-unknown}" \
    "${health_status:-unknown}" \
    "${synced_revision:0:12}"

  if [[ "${sync_status}" == "Synced" &&
        "${synced_revision}" == "${desired_revision}" ]]; then
    break
  fi

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" -o yaml || true
  die "Timed out waiting for Argo CD to sync revision ${desired_revision}."
fi

wait_for_analysis_template "${ANALYSIS_TEMPLATE}" "pre-promotion"
wait_for_analysis_template "${POST_ANALYSIS_TEMPLATE}" "post-promotion"

echo "==> Waiting for the Rollout to exist"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if oc get rollout "${APP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    break
  fi
  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  die "Timed out waiting for Rollout ${APP_NAME}."
fi

echo "==> Waiting for rollout pods to appear"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  pod_count="$(oc get pod -n "${NAMESPACE}" -l app="${APP_NAME}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( pod_count > 0 )); then
    break
  fi
  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  die "Timed out waiting for rollout pods."
fi

echo "==> Waiting for rollout pods to become Ready"
oc wait \
  --for=condition=Ready \
  pod \
  -l app="${APP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT_SECONDS}s"

echo
echo "==> Current resources"
oc get analysistemplate,analysisrun,rollout,rs,pod,svc,route \
  -n "${NAMESPACE}" 2>/dev/null || \
oc get analysistemplate,rollout,rs,pod,svc,route \
  -n "${NAMESPACE}"

active_host="$(oc get route "${APP_NAME}" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"

echo
echo "Blue/Green Argo Rollout deployed through Argo CD."
echo "Git revision: ${desired_revision}"
echo "Desired image: ${desired_image}"
echo "Active URL : https://${active_host}"
echo "Preview URL: https://${preview_host}"
echo
echo "Analysis templates:"
echo "  PRE : ${ANALYSIS_TEMPLATE}"
echo "  POST: ${POST_ANALYSIS_TEMPLATE}"

echo
if oc argo rollouts version >/dev/null 2>&1; then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}"
else
  echo "Tip: install the Argo Rollouts oc plugin to use 'oc argo rollouts get rollout'."
fi

echo
case "${desired_image}" in
  argoproj/rollouts-demo:blue)
    echo "Next step:"
    echo "  bash scripts/switch-green.sh --preview-only"
    ;;
  *)
    echo "The repository currently requests ${desired_image}."
    echo "A new pod-template revision is required to exercise PRE -> promote -> POST again."
    ;;
esac
