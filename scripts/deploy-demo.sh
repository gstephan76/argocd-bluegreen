#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ANALYSIS_TEMPLATE="${ANALYSIS_TEMPLATE:-bluegreen-demo-smoke-test}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
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

oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster. Run 'oc login' first."

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

echo "==> Applying RolloutManager bootstrap"
oc apply -k bootstrap

echo "==> Waiting for RolloutManager ${ROLLOUT_MANAGER} to become available"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rolloutmanager "${ROLLOUT_MANAGER}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  controller="$(oc get rolloutmanager "${ROLLOUT_MANAGER}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.rolloutController}' 2>/dev/null || true)"

  if [[ "${phase}" == "Available" || "${controller}" == "Available" ]]; then
    echo "    RolloutManager is available."
    break
  fi

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get rolloutmanager "${ROLLOUT_MANAGER}" -n "${NAMESPACE}" -o yaml || true
  die "Timed out waiting for RolloutManager."
fi

echo "==> Creating/updating the Argo CD Application"
oc apply -f argocd/application.yaml

echo "==> Waiting for Argo CD Application ${APP_NAME} to become Synced"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync_status="$(oc get application "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(oc get application "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"

  printf '    sync=%s health=%s\n' \
    "${sync_status:-unknown}" \
    "${health_status:-unknown}"

  if [[ "${sync_status}" == "Synced" ]]; then
    break
  fi

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get application "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" -o yaml || true
  die "Timed out waiting for the Argo CD Application."
fi

echo "==> Verifying the pre-promotion AnalysisTemplate"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if oc get analysistemplate "${ANALYSIS_TEMPLATE}" \
    -n "${NAMESPACE}" >/dev/null 2>&1; then
    echo "    AnalysisTemplate ${ANALYSIS_TEMPLATE} is present."
    break
  fi
  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  die "Timed out waiting for AnalysisTemplate ${ANALYSIS_TEMPLATE}."
fi

echo "==> Waiting for the initial Rollout to exist"
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

echo "==> Waiting for initial BLUE pods to appear"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  pod_count="$(oc get pod -n "${NAMESPACE}" -l app="${APP_NAME}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if (( pod_count > 0 )); then
    break
  fi
  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  die "Timed out waiting for initial BLUE pods."
fi

echo "==> Waiting for initial BLUE pods to become Ready"
oc wait \
  --for=condition=Ready \
  pod \
  -l app="${APP_NAME}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT_SECONDS}s"

echo
echo "==> Current resources"
oc get analysistemplate,rollout,rs,pod,svc,route -n "${NAMESPACE}"

active_host="$(oc get route "${APP_NAME}" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"

echo
echo "BLUE demo deployed through Argo CD."
echo "Active URL : https://${active_host}"
echo "Preview URL: https://${preview_host}"
echo
echo "Initial desired image:"
awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print "  " $2; exit}' \
  bluegreen-demo/rollout.yaml

echo
echo "Pre-promotion analysis template:"
echo "  ${ANALYSIS_TEMPLATE}"
echo "  (No AnalysisRun is expected for the initial creation; it runs on the next revision.)"

echo
if oc argo rollouts version >/dev/null 2>&1; then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}"
else
  echo "Tip: install the Argo Rollouts oc plugin to use 'oc argo rollouts get rollout'."
fi

echo
echo "Next step:"
echo "  bash scripts/switch-green.sh"
