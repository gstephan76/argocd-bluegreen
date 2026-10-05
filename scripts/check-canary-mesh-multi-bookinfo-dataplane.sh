#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
ROLLOUT_NAME="${ROLLOUT_NAME:-bookinfo-b}"
DEMO_NAME="${DEMO_NAME:-canary-mesh-multi-bookinfo}"
BLACKBOX_APP="${BLACKBOX_APP:-bookinfo-b-blackbox}"
GATEWAY_COMPONENT="${GATEWAY_COMPONENT:-canary-mesh-multi-bookinfo-ingressgateway}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }

for c in oc jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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
  "rollout.argoproj.io/${ROLLOUT_NAME}"
  "virtualservice.networking.istio.io/bookinfo-a"
  "virtualservice.networking.istio.io/bookinfo-b"
  "gateway.networking.istio.io/${DEMO_NAME}-gateway"
  "route.route.openshift.io/bookinfo-a"
  "route.route.openshift.io/bookinfo-b"
  "service/bookinfo-a-productpage"
  "service/bookinfo-a-details"
  "service/bookinfo-a-reviews"
  "service/bookinfo-a-ratings"
  "service/bookinfo-b-productpage-stable"
  "service/bookinfo-b-productpage-canary"
  "service/bookinfo-b-details-stable"
  "service/bookinfo-b-details-canary"
  "service/bookinfo-b-reviews-stable"
  "service/bookinfo-b-reviews-canary"
  "service/bookinfo-b-ratings-stable"
  "service/bookinfo-b-ratings-canary"
  "service/istio-ingressgateway"
  "deployment/bookinfo-a-productpage"
  "deployment/bookinfo-a-details"
  "deployment/bookinfo-a-reviews"
  "deployment/bookinfo-a-ratings"
  "deployment/bookinfo-b-details-stable"
  "deployment/bookinfo-b-details-canary"
  "deployment/bookinfo-b-reviews-stable"
  "deployment/bookinfo-b-reviews-canary"
  "deployment/bookinfo-b-ratings-stable"
  "deployment/bookinfo-b-ratings-canary"
  "deployment/${BLACKBOX_APP}"
  "deployment/istio-ingressgateway"
  "analysistemplate.argoproj.io/bookinfo-b-prometheus"
  "podmonitor.monitoring.coreos.com/istio-proxies-monitor"
  "servicemonitor.monitoring.coreos.com/${BLACKBOX_APP}"
)

echo "==> Waiting for multi-Bookinfo mesh resources"
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
(( SECONDS < deadline )) || die "Timed out waiting for multi-Bookinfo mesh resources"
pass "Required routing, application, and monitoring resources exist"

gateway_component="$(
  oc get gateway.networking.istio.io "${DEMO_NAME}-gateway" -n "$NAMESPACE" -o json |
    jq -r '.spec.selector["app.kubernetes.io/component"] // ""'
)"
[[ "$gateway_component" == "$GATEWAY_COMPONENT" ]] ||
  die "Gateway selector is not isolated: expected component=${GATEWAY_COMPONENT}, got ${gateway_component:-<missing>}"
pass "Shared gateway is isolated to component=${GATEWAY_COMPONENT}"

for deployment in \
  bookinfo-a-productpage bookinfo-a-details bookinfo-a-reviews bookinfo-a-ratings \
  bookinfo-b-details-stable bookinfo-b-details-canary \
  bookinfo-b-reviews-stable bookinfo-b-reviews-canary \
  bookinfo-b-ratings-stable bookinfo-b-ratings-canary \
  "$BLACKBOX_APP" istio-ingressgateway
do
  oc rollout status "deployment/${deployment}" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s" >/dev/null ||
    die "Deployment ${deployment} did not become Available"
done
pass "Bookinfo A and Bookinfo B downstream Deployments are Available"

check_selector_sidecars() {
  local selector="$1" label="$2" json total with_proxy ready_with_proxy
  json="$(oc get pods -n "$NAMESPACE" -l "$selector" -o json 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1

  total="$(jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length' <<<"$json")"
  with_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(
        any(.spec.containers[]?; .name == "istio-proxy") or
        any(.spec.initContainers[]?; .name == "istio-proxy" and .restartPolicy == "Always")
      )
    ] | length' <<<"$json"
  )"
  ready_with_proxy="$(
    jq '[.items[] |
      select(.metadata.deletionTimestamp == null) |
      select(
        any(.status.containerStatuses[]?; .name == "istio-proxy" and .ready == true) or
        any(.status.initContainerStatuses[]?; .name == "istio-proxy" and .ready == true)
      )
    ] | length' <<<"$json"
  )"
  printf '    %-28s total=%s proxy-ready=%s\n' "$label" "$total" "$ready_with_proxy"
  (( total > 0 && with_proxy == total && ready_with_proxy == total ))
}

echo "==> Waiting for every application pod to have a Ready Istio proxy"
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
(( SECONDS < deadline )) || die "One or more multi-Bookinfo pods lack a Ready istio-proxy"
pass "Both Bookinfo applications have Ready Istio proxies"

for service in \
  bookinfo-a-productpage bookinfo-a-details bookinfo-a-reviews bookinfo-a-ratings \
  bookinfo-b-details-stable bookinfo-b-details-canary \
  bookinfo-b-reviews-stable bookinfo-b-reviews-canary \
  bookinfo-b-ratings-stable bookinfo-b-ratings-canary \
  "$BLACKBOX_APP" istio-ingressgateway
do
  addresses="$(oc get endpoints "$service" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$addresses" ]] || die "Service ${NAMESPACE}/${service} has no ready endpoint"
done
pass "Static and stable/canary downstream Services have ready endpoints"

a_host="$(oc get virtualservice.networking.istio.io bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].destination.host}')"
[[ "$a_host" == "bookinfo-a-productpage" ]] || die "Bookinfo A VirtualService destination is ${a_host:-missing}"

b_stable="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].destination.host}')"
b_canary="$(oc get virtualservice.networking.istio.io bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].destination.host}')"
[[ "$b_stable" == "bookinfo-b-productpage-stable" ]] || die "Bookinfo B stable destination is ${b_stable:-missing}"
[[ "$b_canary" == "bookinfo-b-productpage-canary" ]] || die "Bookinfo B canary destination is ${b_canary:-missing}"
pass "Bookinfo A is static and Bookinfo B points at Rollout stable/canary productpage Services"

route_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
route_b="$(oc get route bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$route_a" && -n "$route_b" && "$route_a" != "$route_b" ]] || die "External route hosts are missing or not distinct"
pass "Two distinct external route hosts exist"

echo
echo "Multi-Bookinfo Service Mesh data-plane check passed."
