#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
A_ROLLOUT="${A_ROLLOUT:-bookinfo-a}"
B_ROLLOUT="${B_ROLLOUT:-bookinfo-b}"
SHARED_VIRTUALSERVICE="${SHARED_VIRTUALSERVICE:-full-demo-router}"
A_ROUTE_NAME="${A_ROUTE_NAME:-bookinfo-a-primary}"
B_ROUTE_NAME="${B_ROUTE_NAME:-bookinfo-b-primary}"
TARGET_HEADER="${TARGET_HEADER:-x-bookinfo-target}"
A_HEADER_VALUE="${A_HEADER_VALUE:-a}"
B_HEADER_VALUE="${B_HEADER_VALUE:-b}"
DEMO_ROUTE="${DEMO_ROUTE:-full-demo}"
GATEWAY="${GATEWAY:-canary-mesh-full-demo-gateway}"
GATEWAY_COMPONENT="${GATEWAY_COMPONENT:-canary-mesh-full-demo-ingressgateway}"
BLACKBOX_APP="${BLACKBOX_APP:-bookinfo-b-blackbox}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }
for c in oc jq curl; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

discovery="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio-discovery}' 2>/dev/null || true)"
injection="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null || true)"
ambient="$(oc get namespace "$NAMESPACE" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}' 2>/dev/null || true)"
[[ "$discovery" == "enabled" ]] || die "Namespace ${NAMESPACE} is not labeled istio-discovery=enabled"
[[ "$injection" == "enabled" ]] || die "Namespace ${NAMESPACE} is not labeled istio-injection=enabled"
[[ "$ambient" != "ambient" ]] || die "Namespace ${NAMESPACE} is also labeled for ambient mode"
pass "Namespace is enrolled for OSSM sidecar mode"

required_resources=(
  "rollout.argoproj.io/${A_ROLLOUT}"
  "rollout.argoproj.io/${B_ROLLOUT}"
  "virtualservice.networking.istio.io/${SHARED_VIRTUALSERVICE}"
  "gateway.networking.istio.io/${GATEWAY}"
  "route.route.openshift.io/${DEMO_ROUTE}"
  "service/istio-ingressgateway"
  "deployment/istio-ingressgateway"
  "analysistemplate.argoproj.io/bookinfo-b-prometheus"
  "deployment/${BLACKBOX_APP}"
  "service/${BLACKBOX_APP}"
  "servicemonitor.monitoring.coreos.com/${BLACKBOX_APP}"
  "podmonitor.monitoring.coreos.com/istio-proxies-monitor"
)
for instance in bookinfo-a bookinfo-b; do
  for svc in productpage-stable productpage-canary details-stable details-canary reviews-stable reviews-canary ratings-stable ratings-canary; do
    required_resources+=("service/${instance}-${svc}")
  done
  for dep in details-stable details-canary reviews-stable reviews-canary ratings-stable ratings-canary; do
    required_resources+=("deployment/${instance}-${dep}")
  done
done

echo "==> Waiting for full-demo mesh resources"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  missing=0
  for resource in "${required_resources[@]}"; do
    if ! oc get "$resource" -n "$NAMESPACE" >/dev/null 2>&1; then
      printf '    missing: %s\n' "$resource"
      missing=1
    fi
  done
  (( missing == 0 )) && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for full-demo resources"
pass "Required shared routing, Rollouts, application stacks, and monitoring resources exist"

# Full-demo must expose exactly the shared ingress contract, not per-app ingress objects.
for legacy in \
  route.route.openshift.io/bookinfo-a route.route.openshift.io/bookinfo-b \
  virtualservice.networking.istio.io/bookinfo-a \
  virtualservice.networking.istio.io/bookinfo-a-rollout \
  virtualservice.networking.istio.io/bookinfo-b
do
  oc get "$legacy" -n "$NAMESPACE" >/dev/null 2>&1 &&
    die "Unexpected per-application ingress resource exists in full-demo: ${legacy}"
done
pass "Single-Route / single-VirtualService ingress model is enforced"

gateway_component="$(oc get gateway.networking.istio.io "$GATEWAY" -n "$NAMESPACE" -o json | jq -r '.spec.selector["app.kubernetes.io/component"] // ""')"
[[ "$gateway_component" == "$GATEWAY_COMPONENT" ]] || die "Gateway selector is not isolated"
service_component="$(oc get service istio-ingressgateway -n "$NAMESPACE" -o json | jq -r '.spec.selector["app.kubernetes.io/component"] // ""')"
[[ "$service_component" == "$GATEWAY_COMPONENT" ]] || die "Ingress Service selector is not isolated"
pass "Shared ingress gateway selectors are isolated to ${GATEWAY_COMPONENT}"

for deployment in \
  bookinfo-a-details-stable bookinfo-a-details-canary \
  bookinfo-a-reviews-stable bookinfo-a-reviews-canary \
  bookinfo-a-ratings-stable bookinfo-a-ratings-canary \
  bookinfo-b-details-stable bookinfo-b-details-canary \
  bookinfo-b-reviews-stable bookinfo-b-reviews-canary \
  bookinfo-b-ratings-stable bookinfo-b-ratings-canary \
  "$BLACKBOX_APP" istio-ingressgateway
do
  oc rollout status "deployment/${deployment}" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s" >/dev/null ||
    die "Deployment ${deployment} did not become Available"
done
pass "Both stable/canary downstream stacks and shared ingress are Available"

check_selector_sidecars() {
  local selector="$1" label="$2" json total with_proxy ready_with_proxy
  json="$(oc get pods -n "$NAMESPACE" -l "$selector" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  total="$(jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length' <<<"$json")"
  with_proxy="$(jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.spec.containers[]?; .name == "istio-proxy") or any(.spec.initContainers[]?; .name == "istio-proxy" and .restartPolicy == "Always"))] | length' <<<"$json")"
  ready_with_proxy="$(jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.containerStatuses[]?; .name == "istio-proxy" and .ready == true) or any(.status.initContainerStatuses[]?; .name == "istio-proxy" and .ready == true))] | length' <<<"$json")"
  printf '    %-28s total=%s proxy-ready=%s\n' "$label" "$total" "$ready_with_proxy"
  (( total > 0 && with_proxy == total && ready_with_proxy == total ))
}

echo "==> Waiting for Ready Istio proxies"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  ok=1
  check_selector_sidecars "app.kubernetes.io/instance=bookinfo-a" "Bookinfo A" || ok=0
  check_selector_sidecars "app.kubernetes.io/instance=bookinfo-b" "Bookinfo B" || ok=0
  check_selector_sidecars "app=${BLACKBOX_APP}" "Bookinfo B blackbox" || ok=0
  check_selector_sidecars "istio=ingressgateway,app.kubernetes.io/component=${GATEWAY_COMPONENT}" "shared ingress gateway" || ok=0
  (( ok == 1 )) && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "One or more full-demo pods lack a Ready istio-proxy"
pass "Both Bookinfo applications and the blackbox have Ready Istio proxies"

for instance in bookinfo-a bookinfo-b; do
  for service in productpage-stable productpage-canary details-stable details-canary reviews-stable reviews-canary ratings-stable ratings-canary; do
    addresses="$(oc get endpoints "${instance}-${service}" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    [[ -n "$addresses" ]] || die "Service ${instance}-${service} has no ready endpoint"
  done
done
for service in "$BLACKBOX_APP" istio-ingressgateway; do
  addresses="$(oc get endpoints "$service" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$addresses" ]] || die "Service ${service} has no ready endpoint"
done
pass "Stable/canary application Services have ready endpoints"

vs_json="$(oc get virtualservice.networking.istio.io "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o json)"
check_vs_route() {
  local route="$1" value="$2" instance="$3" stable canary header
  stable="$(jq -r --arg route "$route" '.spec.http[] | select(.name == $route) | .route[0].destination.host // empty' <<<"$vs_json")"
  canary="$(jq -r --arg route "$route" '.spec.http[] | select(.name == $route) | .route[1].destination.host // empty' <<<"$vs_json")"
  header="$(jq -r --arg route "$route" --arg header "$TARGET_HEADER" '.spec.http[] | select(.name == $route) | .match[0].headers[$header].exact // empty' <<<"$vs_json")"
  [[ "$stable" == "${instance}-productpage-stable" ]] || die "${route} stable destination is ${stable:-missing}"
  [[ "$canary" == "${instance}-productpage-canary" ]] || die "${route} canary destination is ${canary:-missing}"
  [[ "$header" == "$value" ]] || die "${route} does not match ${TARGET_HEADER}: ${value}"
}
check_vs_route "$A_ROUTE_NAME" "$A_HEADER_VALUE" bookinfo-a
check_vs_route "$B_ROUTE_NAME" "$B_HEADER_VALUE" bookinfo-b
pass "Shared VirtualService selects Bookinfo A/B by ${TARGET_HEADER} and keeps independent weighted routes"

for spec in "bookinfo-a:${A_ROUTE_NAME}" "bookinfo-b:${B_ROUTE_NAME}"; do
  instance="${spec%%:*}"; route_name="${spec#*:}"
  stable_service="$(oc get rollout "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.strategy.canary.stableService}' 2>/dev/null || true)"
  canary_service="$(oc get rollout "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.strategy.canary.canaryService}' 2>/dev/null || true)"
  rollout_vs="$(oc get rollout "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.strategy.canary.trafficRouting.istio.virtualService.name}' 2>/dev/null || true)"
  rollout_route="$(oc get rollout "$instance" -n "$NAMESPACE" -o jsonpath='{.spec.strategy.canary.trafficRouting.istio.virtualService.routes[0]}' 2>/dev/null || true)"
  [[ "$stable_service" == "${instance}-productpage-stable" ]] || die "${instance} stableService mismatch"
  [[ "$canary_service" == "${instance}-productpage-canary" ]] || die "${instance} canaryService mismatch"
  [[ "$rollout_vs" == "$SHARED_VIRTUALSERVICE" ]] || die "${instance} does not target shared VirtualService"
  [[ "$rollout_route" == "$route_name" ]] || die "${instance} does not own expected named HTTP route"
done
pass "Both independent Rollouts target distinct named routes inside the shared VirtualService"

host="$(oc get route "$DEMO_ROUTE" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Shared external Route host is missing"

body_a="$(curl -sk -H "${TARGET_HEADER}: ${A_HEADER_VALUE}" "https://${host}/productpage" || true)"
body_b="$(curl -sk -H "${TARGET_HEADER}: ${B_HEADER_VALUE}" "https://${host}/productpage" || true)"
grep -q 'Book Details' <<<"$body_a" && grep -q 'Book Reviews' <<<"$body_a" || die "Header-selected Bookinfo A request failed"
grep -q 'Book Details' <<<"$body_b" && grep -q 'Book Reviews' <<<"$body_b" || die "Header-selected Bookinfo B request failed"
pass "Single external Route reaches both applications through header selection"

echo
echo "full-demo Service Mesh data-plane check passed."
