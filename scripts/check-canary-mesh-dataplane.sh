#!/usr/bin/env bash
set -Eeuo pipefail
NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
APP_NAME="${APP_NAME:-rollouts-mesh-canary-demo}"
BLACKBOX_APP="${BLACKBOX_APP:-rollouts-mesh-canary-blackbox}"
GATEWAY_COMPONENT="${GATEWAY_COMPONENT:-rollouts-mesh-canary-ingressgateway}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
die(){ echo "ERROR: $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }
for c in oc jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

discovery="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null || true)"
injection="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)"
ambient="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || true)"
[[ "$discovery" == "enabled" ]] || die "Namespace ${NAMESPACE} is not labeled istio-discovery=enabled"
[[ "$injection" == "enabled" ]] || die "Namespace ${NAMESPACE} is not labeled istio-injection=enabled"
[[ "$ambient" != "ambient" ]] || die "Namespace ${NAMESPACE} is also labeled for ambient mode"
pass "Namespace is enrolled for OSSM sidecar mode"

required_resources=(
  "rollout.argoproj.io/${APP_NAME}"
  "virtualservice.networking.istio.io/rollouts-mesh-canary"
  "gateway.networking.istio.io/rollouts-mesh-canary-gateway"
  "route.route.openshift.io/rollouts-mesh-canary-demo"
  "service/rollouts-mesh-canary-stable"
  "service/rollouts-mesh-canary-canary"
  "service/istio-ingressgateway"
  "deployment/rollouts-mesh-canary-blackbox"
  "deployment/istio-ingressgateway"
  "analysistemplate.argoproj.io/rollouts-mesh-canary-prometheus"
  "podmonitor.monitoring.coreos.com/istio-proxies-monitor"
)
echo "==> Waiting for mesh routing, monitoring, and workload resources"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  missing=0
  for resource in "${required_resources[@]}"; do
    if ! oc get "$resource" -n "$NAMESPACE" >/dev/null 2>&1; then printf '    missing: %s\n' "$resource"; missing=1; fi
  done
  (( missing == 0 )) && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for mesh data-plane resources"
pass "Required mesh routing and monitoring resources exist"

gateway_component="$(oc get gateway.networking.istio.io rollouts-mesh-canary-gateway -n "$NAMESPACE" -o json |
  jq -r '.spec.selector["app.kubernetes.io/component"] // ""')"
[[ "$gateway_component" == "$GATEWAY_COMPONENT" ]] ||
  die "Gateway selector is not isolated: expected app.kubernetes.io/component=${GATEWAY_COMPONENT}, got ${gateway_component:-<missing>}"
pass "Gateway selector is isolated to component=${GATEWAY_COMPONENT}"

check_selector_sidecars() {
  local selector="$1" label="$2" json total classic_proxy native_proxy with_proxy ready_with_proxy
  json="$(oc get pods -n "$NAMESPACE" -l "$selector" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1

  total="$(jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length' <<<"$json")"

  classic_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(any(.spec.containers[]?; .name == "istio-proxy"))
    ] | length' <<<"$json"
  )"

  native_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(any(.spec.initContainers[]?;
        .name == "istio-proxy" and .restartPolicy == "Always"))
    ] | length' <<<"$json"
  )"

  with_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(
        any(.spec.containers[]?; .name == "istio-proxy") or
        any(.spec.initContainers[]?;
          .name == "istio-proxy" and .restartPolicy == "Always")
      )
    ] | length' <<<"$json"
  )"

  ready_with_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(
        any(.status.containerStatuses[]?;
          .name == "istio-proxy" and .ready == true) or
        any(.status.initContainerStatuses[]?;
          .name == "istio-proxy" and .ready == true)
      )
    ] | length' <<<"$json"
  )"

  printf '    %-20s total=%s classic=%s native=%s proxy-ready=%s\n' \
    "$label" "$total" "$classic_proxy" "$native_proxy" "$ready_with_proxy"

  (( total > 0 && with_proxy == total && ready_with_proxy == total ))
}

echo "==> Waiting for every active mesh-demo pod to have a Ready istio-proxy"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  app_ok=0; blackbox_ok=0; gateway_ok=0
  check_selector_sidecars "app=${APP_NAME}" "rollout pods" && app_ok=1 || true
  check_selector_sidecars "app=${BLACKBOX_APP}" "blackbox" && blackbox_ok=1 || true
  check_selector_sidecars "istio=ingressgateway,app.kubernetes.io/component=${GATEWAY_COMPONENT}" "ingress gateway" && gateway_ok=1 || true
  (( app_ok && blackbox_ok && gateway_ok )) && break
  sleep "$POLL_SECONDS"
done
if ! (( app_ok && blackbox_ok && gateway_ok )); then
  echo "Pods still missing a Ready istio-proxy:" >&2
  oc get pods -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name,INIT-CONTAINERS:.spec.initContainers[*].name' \
    >&2 || true
  echo "Note: OSSM/Istio native sidecars appear under initContainers with restartPolicy=Always." >&2
  die "Service Mesh data plane is incomplete; refusing to continue without sidecars"
fi
pass "All active mesh-demo workloads have Ready Istio proxies"
