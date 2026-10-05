#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUT_MANAGER_NAMESPACE="${ROLLOUT_MANAGER_NAMESPACE:-openshift-gitops}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
MONITORING_TIMEOUT_SECONDS="${MONITORING_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk grep curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

export NAMESPACE APP_NAME ARGOCD_NAMESPACE
mesh_enable_failure_diagnostics

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
  applications.argoproj.io rollouts.argoproj.io rolloutmanagers.argoproj.io \
  analysistemplates.argoproj.io analysisruns.argoproj.io \
  servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com \
  gateways.networking.istio.io virtualservices.networking.istio.io
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done

for asset in \
  canary-mesh-bookinfo/kustomization.yaml \
  canary-mesh-bookinfo/workloads.yaml \
  canary-mesh-bookinfo/rollout.yaml \
  canary-mesh-bookinfo/analysis-template.yaml \
  argocd/application-canary-mesh-bookinfo.yaml \
  bootstrap/canary-mesh-bookinfo-prometheus-access.yaml \
  scripts/check-canary-mesh-bookinfo-dataplane.sh
do
  [[ -f "$asset" ]] || die "Required asset not found: $asset"
done

echo "==> Ensuring namespace ${NAMESPACE} exists and is enrolled in OSSM"
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
  printf '%s\n' "$existing_monitoring_config" >&2
  die "Refusing to overwrite existing monitoring settings"
fi

oc rollout status statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring \
  --timeout="${MONITORING_TIMEOUT_SECONDS}s"
oc get service thanos-querier -n openshift-monitoring >/dev/null 2>&1 ||
  die "OpenShift Thanos Querier service was not found"

echo "==> Applying Argo Rollouts bootstrap"
oc apply -k bootstrap

echo "==> Waiting for RolloutManager ${ROLLOUT_MANAGER}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rolloutmanager "$ROLLOUT_MANAGER" -n "$ROLLOUT_MANAGER_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  controller="$(oc get rolloutmanager "$ROLLOUT_MANAGER" -n "$ROLLOUT_MANAGER_NAMESPACE" -o jsonpath='{.status.rolloutController}' 2>/dev/null || true)"
  [[ "$phase" == "Available" || "$controller" == "Available" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for RolloutManager"

echo "==> Applying Prometheus access for whole-Bookinfo analysis"
oc apply -f bootstrap/canary-mesh-bookinfo-prometheus-access.yaml

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  token_data="$(oc get secret canary-mesh-bookinfo-prometheus-token -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for canary-mesh-bookinfo-prometheus-token"

echo "==> Server-validating whole-Bookinfo demo manifests"
oc apply --dry-run=server -f bootstrap/canary-mesh-bookinfo-prometheus-access.yaml >/dev/null
oc apply --dry-run=server -k canary-mesh-bookinfo >/dev/null

echo "==> Applying Argo CD Application"
oc apply -f argocd/application-canary-mesh-bookinfo.yaml
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${desired_revision:0:12}"
mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$desired_revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
  die "Argo CD did not reconcile exact revision ${desired_revision}"

echo "==> Verifying the complete whole-Bookinfo mesh data plane"
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-bookinfo-dataplane.sh

host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Route host is empty"

echo "==> Verifying Bookinfo through the ingress path without changing rollout state"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  body="$(curl -sk "https://${host}/productpage" || true)"
  if grep -q 'Book Details' <<<"$body" &&
     grep -q 'Book Reviews' <<<"$body" &&
     grep -q 'glyphicon glyphicon-star' <<<"$body" &&
     { grep -q 'text-black-500' <<<"$body" || grep -q 'text-red-500' <<<"$body"; }; then
    break
  fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Bookinfo did not become reachable through https://${host}/productpage"

weights="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"
echo "==> Current rollout traffic: ${weights:-unknown}"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Whole-Bookinfo canary demo reconciled idempotently: https://${host}/productpage"
echo "Next: bash scripts/prepare-canary-mesh-bookinfo.sh"
