#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${ROOT_DIR}/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

oc get crd scaledobjects.keda.sh >/dev/null 2>&1 || {
  echo "KEDA is not installed. Run:" >&2
  echo "  ${ROOT_DIR}/scripts/install-keda.sh" >&2
  exit 1
}

echo "==> Verifying user-workload monitoring"
config="$(oc get configmap cluster-monitoring-config \
  -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"

if [[ -z "${config}" ]]; then
  oc apply -f "${REPO_ROOT}/platform-monitoring/user-workload-monitoring.yaml"
elif printf '%s\n' "${config}" | grep -Eq 'enableUserWorkload:[[:space:]]*true'; then
  :
elif printf '%s\n' "${config}" | grep -Eq '^[[:space:]]*enableUserWorkload:[[:space:]]*false[[:space:]]*$' &&
     [[ "$(printf '%s\n' "${config}" | grep -Ev '^[[:space:]]*(#.*)?$|^[[:space:]]*enableUserWorkload:' | wc -l | tr -d ' ')" == "0" ]]; then
  oc apply -f "${REPO_ROOT}/platform-monitoring/user-workload-monitoring.yaml"
else
  die "cluster-monitoring-config has custom settings. Merge 'enableUserWorkload: true' manually instead of overwriting it."
fi

oc rollout status statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring \
  --timeout="${READY_TIMEOUT}s"

echo "==> Deploying the KEDA demonstration workload"
oc apply -k "${ROOT_DIR}/keda/app"

oc rollout status deployment/keda-demo-pushgateway \
  -n "${APP_NAMESPACE}" \
  --timeout="${READY_TIMEOUT}s"

oc wait \
  --for=condition=Ready \
  scaledobject/keda-async-worker \
  -n "${APP_NAMESPACE}" \
  --timeout="${READY_TIMEOUT}s"

echo "==> Initializing synthetic backlog to zero"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0

echo
echo "KEDA demo is Ready at a clean zero-backlog baseline."
oc get scaledobject,hpa,deployment,pod \
  -n "${APP_NAMESPACE}"
echo
echo "Run the complete scaling demonstration:"
echo "  ${ROOT_DIR}/scripts/run-keda-demo.sh"
