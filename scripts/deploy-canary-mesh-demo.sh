#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-mesh-canary-demo}"
ANALYSIS_TEMPLATE="${ANALYSIS_TEMPLATE:-rollouts-mesh-canary-prometheus}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUT_MANAGER_NAMESPACE="${ROLLOUT_MANAGER_NAMESPACE:-openshift-gitops}"
MESH_INGRESS_NAMESPACE="${MESH_INGRESS_NAMESPACE:-$NAMESPACE}"
MESH_INGRESS_SERVICE="${MESH_INGRESS_SERVICE:-istio-ingressgateway}"
ROUTE_NAME="${ROUTE_NAME:-rollouts-mesh-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
MONITORING_TIMEOUT_SECONDS="${MONITORING_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk sed grep curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
mesh_enable_failure_diagnostics

[[ -f scripts/check-canary-mesh-prereqs.sh ]] || \
  die "scripts/check-canary-mesh-prereqs.sh not found"

echo "==> Verifying OpenShift Service Mesh 3.4+ prerequisite"
bash scripts/check-canary-mesh-prereqs.sh

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"
desired_revision="$(git rev-parse HEAD)"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

for crd in \
  applications.argoproj.io \
  rollouts.argoproj.io \
  rolloutmanagers.argoproj.io \
  analysistemplates.argoproj.io \
  analysisruns.argoproj.io \
  servicemonitors.monitoring.coreos.com \
  gateways.networking.istio.io \
  virtualservices.networking.istio.io
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done

[[ -f platform-monitoring/user-workload-monitoring.yaml ]] || \
  die "platform-monitoring/user-workload-monitoring.yaml not found"
[[ -f bootstrap/canary-mesh-prometheus-access.yaml ]] || \
  die "bootstrap/canary-mesh-prometheus-access.yaml not found"
[[ -f argocd/application-canary-mesh.yaml ]] || \
  die "argocd/application-canary-mesh.yaml not found"
[[ -f scripts/check-canary-mesh-dataplane.sh ]] || \
  die "scripts/check-canary-mesh-dataplane.sh not found"
[[ -f scripts/lib-canary-mesh.sh ]] || \
  die "scripts/lib-canary-mesh.sh not found"
[[ -f canary-mesh-demo/podmonitor-istio-proxies.yaml ]] || \
  die "canary-mesh-demo/podmonitor-istio-proxies.yaml not found"

echo "==> Ensuring namespace ${NAMESPACE} exists and is enrolled in the OSSM 3.4+ mesh"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"
oc label namespace "$NAMESPACE" istio-discovery=enabled istio-injection=enabled --overwrite
oc label namespace "$NAMESPACE" istio.io/rev- >/dev/null 2>&1 || true

echo "==> Ensuring OpenShift user-workload monitoring is enabled"
existing_monitoring_config="$(
  oc get configmap cluster-monitoring-config \
    -n openshift-monitoring \
    -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true
)"

if [[ -z "$existing_monitoring_config" ]]; then
  oc apply -f platform-monitoring/user-workload-monitoring.yaml
elif [[ "$existing_monitoring_config" == *"enableUserWorkload: true"* ]]; then
  echo "    user-workload monitoring is already enabled"
elif [[ "$existing_monitoring_config" == "enableUserWorkload: false" ||
        "$existing_monitoring_config" == $'enableUserWorkload: false\n' ]]; then
  oc apply -f platform-monitoring/user-workload-monitoring.yaml
else
  echo "Existing openshift-monitoring/cluster-monitoring-config:" >&2
  printf '%s\n' "$existing_monitoring_config" >&2
  die "Refusing to overwrite existing monitoring settings. Merge 'enableUserWorkload: true' into data.config.yaml."
fi

echo "==> Waiting for prometheus-user-workload"
oc rollout status statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring \
  --timeout="${MONITORING_TIMEOUT_SECONDS}s"
oc get service thanos-querier -n openshift-monitoring >/dev/null 2>&1 || \
  die "OpenShift Thanos Querier service was not found"

echo "==> Applying Argo Rollouts bootstrap"
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
(( SECONDS < deadline )) || die "Timed out waiting for RolloutManager"

echo "==> Applying Prometheus access for the mesh canary"
oc apply -f bootstrap/canary-mesh-prometheus-access.yaml

echo "==> Waiting for Prometheus service-account token"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  token_data="$(oc get secret rollouts-mesh-canary-prometheus-token -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for rollouts-mesh-canary-prometheus-token"

echo "==> Server-validating mesh demo manifests"
oc apply --dry-run=server -f bootstrap/canary-mesh-prometheus-access.yaml >/dev/null
oc apply --dry-run=server -k canary-mesh-demo >/dev/null

echo "==> Applying Argo CD Application"
oc apply -f argocd/application-canary-mesh.yaml
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${desired_revision:0:12}"
if ! mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$desired_revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS"; then
  die "Argo CD did not reconcile exact revision ${desired_revision}"
fi

echo "==> Verifying the complete Service Mesh data plane"
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-dataplane.sh

echo "==> Verifying the dedicated demo ingress gateway and Route"
oc get service "$MESH_INGRESS_SERVICE" -n "$MESH_INGRESS_NAMESPACE" >/dev/null 2>&1 || die "Ingress gateway Service ${MESH_INGRESS_NAMESPACE}/${MESH_INGRESS_SERVICE} not found"

oc get route "$ROUTE_NAME" -n "$MESH_INGRESS_NAMESPACE" >/dev/null 2>&1 || die "Route ${MESH_INGRESS_NAMESPACE}/${ROUTE_NAME} not found"

host="$(oc get route "$ROUTE_NAME" -n "$MESH_INGRESS_NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Route host is empty"

echo "==> Verifying the mesh-routed endpoint"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/" || true)"
  [[ "$code" == "200" ]] && break
  printf '    https://%s/ -> HTTP %s\n' "$host" "${code:-000}"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for https://${host}/ through the mesh gateway"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Mesh canary reconciliation complete: https://${host}"
echo "Istio ingress: ${MESH_INGRESS_NAMESPACE}/${MESH_INGRESS_SERVICE}"
echo "Namespace mesh enrollment: istio-discovery=enabled, istio-injection=enabled"
echo "Next: bash scripts/prepare-canary-mesh-blue.sh"
