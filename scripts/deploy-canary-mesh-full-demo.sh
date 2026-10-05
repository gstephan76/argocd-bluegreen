#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
SHARED_APP="${SHARED_APP:-canary-mesh-full-demo-shared}"
A_APP="${A_APP:-canary-mesh-full-demo-a}"
B_APP="${B_APP:-canary-mesh-full-demo-b}"
APP_NAME="$B_APP"
ROLLOUT_NAME="${ROLLOUT_NAME:-bookinfo-b}"
DEMO_ROUTE="${DEMO_ROUTE:-full-demo}"
TARGET_HEADER="${TARGET_HEADER:-x-bookinfo-target}"
A_HEADER_VALUE="${A_HEADER_VALUE:-a}"
B_HEADER_VALUE="${B_HEADER_VALUE:-b}"
SHARED_VIRTUALSERVICE="${SHARED_VIRTUALSERVICE:-full-demo-router}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUT_MANAGER_NAMESPACE="${ROLLOUT_MANAGER_NAMESPACE:-openshift-gitops}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-420}"
MONITORING_TIMEOUT_SECONDS="${MONITORING_TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git grep curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
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
  git status --short --untracked-files=no >&2 || true
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
for crd in applications.argoproj.io rollouts.argoproj.io rolloutmanagers.argoproj.io analysistemplates.argoproj.io analysisruns.argoproj.io servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com gateways.networking.istio.io virtualservices.networking.istio.io; do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done
for asset in \
  full-demo/shared/kustomization.yaml \
  full-demo/bookinfo-a/kustomization.yaml \
  full-demo/bookinfo-b/kustomization.yaml \
  full-demo/bookinfo-a/rollout.yaml \
  full-demo/bookinfo-b/rollout.yaml \
  argocd/application-canary-mesh-full-demo-shared.yaml \
  argocd/application-canary-mesh-full-demo-a.yaml \
  argocd/application-canary-mesh-full-demo-b.yaml \
  bootstrap/canary-mesh-full-demo-prometheus-access.yaml \
  scripts/check-canary-mesh-full-demo-dataplane.sh; do
  [[ -f "$asset" ]] || die "Required asset not found: $asset"
done

echo "==> Ensuring namespace ${NAMESPACE} exists and is enrolled in OSSM"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"
oc label namespace "$NAMESPACE" istio-discovery=enabled istio-injection=enabled --overwrite
oc label namespace "$NAMESPACE" istio.io/rev- >/dev/null 2>&1 || true

echo "==> Ensuring OpenShift user-workload monitoring is enabled"
existing_monitoring_config="$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
if [[ -z "$existing_monitoring_config" ]]; then
  oc apply -f platform-monitoring/user-workload-monitoring.yaml
elif [[ "$existing_monitoring_config" == *"enableUserWorkload: true"* ]]; then
  echo "    user-workload monitoring is already enabled"
elif [[ "$existing_monitoring_config" == "enableUserWorkload: false" || "$existing_monitoring_config" == $'enableUserWorkload: false\n' ]]; then
  oc apply -f platform-monitoring/user-workload-monitoring.yaml
else
  printf '%s\n' "$existing_monitoring_config" >&2
  die "Refusing to overwrite existing monitoring settings"
fi
oc rollout status statefulset/prometheus-user-workload -n openshift-user-workload-monitoring --timeout="${MONITORING_TIMEOUT_SECONDS}s"
oc get service thanos-querier -n openshift-monitoring >/dev/null 2>&1 || die "OpenShift Thanos Querier service was not found"

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
oc apply -f bootstrap/canary-mesh-full-demo-prometheus-access.yaml
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  token_data="$(oc get secret canary-mesh-full-demo-prometheus-token -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for canary-mesh-full-demo-prometheus-token"

echo "==> Server-validating full-demo manifests"
oc apply --dry-run=server -f bootstrap/canary-mesh-full-demo-prometheus-access.yaml >/dev/null
oc apply --dry-run=server -k full-demo/shared >/dev/null
oc apply --dry-run=server -k full-demo/bookinfo-a >/dev/null
oc apply --dry-run=server -k full-demo/bookinfo-b >/dev/null

# Bootstrap ordering is deliberate: the shared weighted VirtualService must exist
# before either Rollout is admitted/reconciled against it.
echo "==> Applying shared Argo CD Application first"
oc apply -f argocd/application-canary-mesh-full-demo-shared.yaml
oc annotate applications.argoproj.io "$SHARED_APP" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
mesh_wait_argocd_revision "$SHARED_APP" "$ARGOCD_NAMESPACE" "$desired_revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
  die "Shared Argo CD Application did not reconcile exact revision ${desired_revision}"

echo "==> Applying Bookinfo A and B Argo CD Applications"
oc apply -f argocd/application-canary-mesh-full-demo-a.yaml
oc apply -f argocd/application-canary-mesh-full-demo-b.yaml
for app in "$A_APP" "$B_APP"; do
  oc annotate applications.argoproj.io "$app" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  mesh_wait_argocd_revision "$app" "$ARGOCD_NAMESPACE" "$desired_revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS" ||
    die "Argo CD Application ${app} did not reconcile exact revision ${desired_revision}"
done

echo "==> Verifying the complete full-demo mesh data plane"
TIMEOUT_SECONDS="$TIMEOUT_SECONDS" bash scripts/check-canary-mesh-full-demo-dataplane.sh

host="$(oc get route "$DEMO_ROUTE" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Shared Route host is missing"
for target in "$A_HEADER_VALUE" "$B_HEADER_VALUE"; do
  deadline=$((SECONDS + TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    body="$(curl -sk -H "${TARGET_HEADER}: ${target}" "https://${host}/productpage" || true)"
    grep -q 'Book Details' <<<"$body" && grep -q 'Book Reviews' <<<"$body" && break
    sleep "$POLL_SECONDS"
  done
  (( SECONDS < deadline )) || die "Header-selected Bookinfo target ${target} did not become reachable"
done

a_weights="$(oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='A-stable={.spec.http[?(@.name=="bookinfo-a-primary")].route[0].weight}% A-canary={.spec.http[?(@.name=="bookinfo-a-primary")].route[1].weight}%')"
b_weights="$(oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='B-stable={.spec.http[?(@.name=="bookinfo-b-primary")].route[0].weight}% B-canary={.spec.http[?(@.name=="bookinfo-b-primary")].route[1].weight}%')"
echo
echo "full-demo ready: https://${host}/productpage"
echo "  Bookinfo A header: ${TARGET_HEADER}: ${A_HEADER_VALUE} (${a_weights})"
echo "  Bookinfo B header: ${TARGET_HEADER}: ${B_HEADER_VALUE} (${b_weights})"
echo "Next: bash scripts/prepare-canary-mesh-full-demo.sh"
