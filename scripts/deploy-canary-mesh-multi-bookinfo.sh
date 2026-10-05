#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
SHARED_APP="${SHARED_APP:-canary-mesh-multi-bookinfo-shared}"
A_APP="${A_APP:-canary-mesh-multi-bookinfo-a}"
B_APP="${B_APP:-canary-mesh-multi-bookinfo-b}"
APP_NAME="$B_APP"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
ROLLOUT_NAME="$B_ROLLOUT"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUT_MANAGER_NAMESPACE="${ROLLOUT_MANAGER_NAMESPACE:-openshift-gitops}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
MONITORING_TIMEOUT_SECONDS="${MONITORING_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git awk grep curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

export NAMESPACE APP_NAME ARGOCD_NAMESPACE ROLLOUT_NAME
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
  canary-mesh-multi-bookinfo/shared/kustomization.yaml \
  canary-mesh-multi-bookinfo/bookinfo-a/kustomization.yaml \
  canary-mesh-multi-bookinfo/bookinfo-b/kustomization.yaml \
  canary-mesh-multi-bookinfo/bookinfo-a/rollout.yaml \
  canary-mesh-multi-bookinfo/bookinfo-b/rollout.yaml \
  argocd/application-canary-mesh-multi-bookinfo-shared.yaml \
  argocd/application-canary-mesh-multi-bookinfo-a.yaml \
  argocd/application-canary-mesh-multi-bookinfo-b.yaml \
  bootstrap/canary-mesh-multi-bookinfo-prometheus-access.yaml \
  scripts/check-canary-mesh-multi-bookinfo-dataplane.sh
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

echo "==> Applying Prometheus access for Bookinfo B analysis"
oc apply -f bootstrap/canary-mesh-multi-bookinfo-prometheus-access.yaml

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  token_data="$(oc get secret canary-mesh-multi-bookinfo-prometheus-token -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for canary-mesh-multi-bookinfo-prometheus-token"

echo "==> Server-validating multi-Bookinfo manifests"
oc apply --dry-run=server -f bootstrap/canary-mesh-multi-bookinfo-prometheus-access.yaml >/dev/null
oc apply --dry-run=server -k canary-mesh-multi-bookinfo/shared >/dev/null
oc apply --dry-run=server -k canary-mesh-multi-bookinfo/bookinfo-a >/dev/null
oc apply --dry-run=server -k canary-mesh-multi-bookinfo/bookinfo-b >/dev/null

echo "==> Applying three Argo CD Applications"
oc apply -f argocd/application-canary-mesh-multi-bookinfo-shared.yaml
oc apply -f argocd/application-canary-mesh-multi-bookinfo-a.yaml
oc apply -f argocd/application-canary-mesh-multi-bookinfo-b.yaml

for app in "$SHARED_APP" "$A_APP" "$B_APP"; do
  oc annotate applications.argoproj.io "$app" \
    -n "$ARGOCD_NAMESPACE" \
    argocd.argoproj.io/refresh=hard \
    --overwrite >/dev/null
done

echo "==> Waiting for all Argo CD Applications at revision ${desired_revision:0:12}"
for app in "$SHARED_APP" "$A_APP" "$B_APP"; do
  mesh_wait_argocd_revision "$app" "$ARGOCD_NAMESPACE" "$desired_revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
    die "Argo CD Application ${app} did not reconcile exact revision ${desired_revision}"
done

echo "==> Verifying the complete multi-Bookinfo mesh data plane"
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh

host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
host_b="$(oc get route bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host_a" && -n "$host_b" && "$host_a" != "$host_b" ]] || die "Route hosts are missing or not distinct"

echo "==> Verifying Bookinfo A Rollout through its ingress route without changing rollout state"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  body="$(curl -sk "https://${host_a}/productpage" || true)"
  if grep -q 'Book Details' <<<"$body" &&
     grep -q 'Book Reviews' <<<"$body" &&
     grep -q 'glyphicon glyphicon-star' <<<"$body" &&
     { grep -q 'text-black-500' <<<"$body" || grep -q 'text-red-500' <<<"$body"; }; then
    break
  fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Bookinfo A did not become reachable through https://${host_a}/productpage"

echo "==> Verifying Bookinfo B through its route without changing rollout state"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  body="$(curl -sk "https://${host_b}/productpage" || true)"
  if grep -q 'Book Details' <<<"$body" &&
     grep -q 'Book Reviews' <<<"$body" &&
     grep -q 'glyphicon glyphicon-star' <<<"$body" &&
     { grep -q 'text-black-500' <<<"$body" || grep -q 'text-red-500' <<<"$body"; }; then
    break
  fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Bookinfo B did not become reachable through https://${host_b}/productpage"

weights_a="$(oc get virtualservice.networking.istio.io bookinfo-a -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"
weights_b="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"

echo
echo "Bookinfo A (Rollout; not exercised by this demo): https://${host_a}/productpage"
echo "Bookinfo B (Rollout; exercised by this demo): https://${host_b}/productpage"
echo "Bookinfo A traffic: ${weights_a:-unknown}"
echo "Bookinfo B traffic: ${weights_b:-unknown}"
echo "Multi-Bookinfo demo reconciled idempotently."
echo "Next: bash scripts/prepare-canary-mesh-multi-bookinfo.sh"
