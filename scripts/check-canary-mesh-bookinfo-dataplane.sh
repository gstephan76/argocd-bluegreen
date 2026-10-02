#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
BLACKBOX_APP="${BLACKBOX_APP:-canary-mesh-bookinfo-blackbox}"
GATEWAY_COMPONENT="${GATEWAY_COMPONENT:-canary-mesh-bookinfo-ingressgateway}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
pass(){ echo "[PASS] $*"; }

for c in oc jq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
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
  "rollout.argoproj.io/${APP_NAME}"
  "virtualservice.networking.istio.io/${APP_NAME}"
  "gateway.networking.istio.io/${APP_NAME}-gateway"
  "route.route.openshift.io/${APP_NAME}"
  "service/${APP_NAME}-stable"
  "service/${APP_NAME}-canary"
  "service/bookinfo-details-stable"
  "service/bookinfo-details-canary"
  "service/bookinfo-reviews-stable"
  "service/bookinfo-reviews-canary"
  "service/bookinfo-ratings-stable"
  "service/bookinfo-ratings-canary"
  "service/istio-ingressgateway"
  "deployment/bookinfo-details-stable"
  "deployment/bookinfo-details-canary"
  "deployment/bookinfo-reviews-stable"
  "deployment/bookinfo-reviews-canary"
  "deployment/bookinfo-ratings-stable"
  "deployment/bookinfo-ratings-canary"
  "deployment/${BLACKBOX_APP}"
  "deployment/istio-ingressgateway"
  "analysistemplate.argoproj.io/${APP_NAME}-prometheus"
  "podmonitor.monitoring.coreos.com/istio-proxies-monitor"
  "servicemonitor.monitoring.coreos.com/${BLACKBOX_APP}"
)

echo "==> Waiting for whole-Bookinfo mesh resources"
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
(( SECONDS < deadline )) || die "Timed out waiting for whole-Bookinfo mesh resources"
pass "Required routing, application, and monitoring resources exist"

gateway_component="$(
  oc get gateway.networking.istio.io "${APP_NAME}-gateway" -n "$NAMESPACE" -o json |
    jq -r '.spec.selector["app.kubernetes.io/component"] // ""'
)"
[[ "$gateway_component" == "$GATEWAY_COMPONENT" ]] ||
  die "Gateway selector is not isolated: expected component=${GATEWAY_COMPONENT}, got ${gateway_component:-<missing>}"
pass "Gateway selector is isolated to component=${GATEWAY_COMPONENT}"

for deployment in \
  bookinfo-details-stable bookinfo-details-canary \
  bookinfo-reviews-stable bookinfo-reviews-canary \
  bookinfo-ratings-stable bookinfo-ratings-canary \
  "$BLACKBOX_APP" istio-ingressgateway
do
  oc rollout status "deployment/${deployment}" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s" >/dev/null ||
    die "Deployment ${deployment} did not become Available"
done
pass "Stable and canary downstream Bookinfo Deployments are Available"

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

  printf '    %-22s total=%s proxy-ready=%s\n' "$label" "$total" "$ready_with_proxy"
  (( total > 0 && with_proxy == total && ready_with_proxy == total ))
}

echo "==> Waiting for every Bookinfo track pod to have a Ready Istio proxy"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  ok=1
  check_selector_sidecars "app=productpage" "productpage rollout" || ok=0
  check_selector_sidecars "app=details" "details stable+canary" || ok=0
  check_selector_sidecars "app=reviews" "reviews stable+canary" || ok=0
  check_selector_sidecars "app=ratings" "ratings stable+canary" || ok=0
  check_selector_sidecars "app=${BLACKBOX_APP}" "blackbox exporter" || ok=0
  check_selector_sidecars "istio=ingressgateway,app.kubernetes.io/component=${GATEWAY_COMPONENT}" "ingress gateway" || ok=0
  (( ok == 1 )) && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Service Mesh data plane is incomplete; one or more Bookinfo pods lack a Ready istio-proxy"
pass "All stable/canary Bookinfo workloads have Ready Istio proxies"

for service in \
  bookinfo-details-stable bookinfo-details-canary \
  bookinfo-reviews-stable bookinfo-reviews-canary \
  bookinfo-ratings-stable bookinfo-ratings-canary \
  "$BLACKBOX_APP" istio-ingressgateway
do
  addresses="$(oc get endpoints "$service" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "$addresses" ]] || die "Service ${NAMESPACE}/${service} has no ready endpoint"
done
pass "Stable and canary downstream Services have ready endpoints"

stable_host="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].destination.host}')"
canary_host="$(oc get virtualservice.networking.istio.io "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].destination.host}')"
[[ "$stable_host" == "${APP_NAME}-stable" ]] || die "VirtualService stable destination is ${stable_host:-missing}"
[[ "$canary_host" == "${APP_NAME}-canary" ]] || die "VirtualService canary destination is ${canary_host:-missing}"
pass "VirtualService points at the Rollout stable/canary productpage Services"

echo
echo "Whole-Bookinfo Service Mesh data-plane check passed."
