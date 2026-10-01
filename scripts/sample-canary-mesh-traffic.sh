#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
ROUTE_NAME="${ROUTE_NAME:-rollouts-mesh-canary-demo}"
MESH_INGRESS_NAMESPACE="${MESH_INGRESS_NAMESPACE:-$NAMESPACE}"
REQUESTS="${REQUESTS:-100}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl awk sort uniq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

usage() {
  cat <<'EOF'
Usage:
  bash scripts/sample-canary-mesh-traffic.sh [--help]

Environment:
  REQUESTS=<n>              Number of requests to sample (default: 100)
  NAMESPACE=<namespace>     Mesh demo namespace
  MESH_INGRESS_NAMESPACE=  Namespace containing the demo Route
  ROUTE_NAME=<name>         OpenShift Route name
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "Unknown argument: $1" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
[[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS must be a positive integer"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

echo "==> Verifying OpenShift Service Mesh 3.4+ prerequisite"
bash scripts/check-canary-mesh-prereqs.sh
echo "==> Verifying the complete Service Mesh data plane"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}" bash scripts/check-canary-mesh-dataplane.sh

if [[ -z "$MESH_INGRESS_NAMESPACE" ]]; then
  mapfile -t route_namespaces < <(
    oc get route -A \
      -o jsonpath='{range .items[?(@.metadata.name=="'"$ROUTE_NAME"'")]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null || true
  )
  if (( ${#route_namespaces[@]} == 1 )); then
    MESH_INGRESS_NAMESPACE="${route_namespaces[0]}"
  elif (( ${#route_namespaces[@]} == 0 )); then
    die "Route ${ROUTE_NAME} not found. Run scripts/deploy-canary-mesh-demo.sh first."
  else
    printf 'Route %s exists in multiple namespaces:\n' "$ROUTE_NAME" >&2
    printf '  %s\n' "${route_namespaces[@]}" >&2
    die "Set MESH_INGRESS_NAMESPACE explicitly"
  fi
fi

host="$(oc get route "$ROUTE_NAME" -n "$MESH_INGRESS_NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Route host is empty"

weights="$(oc get virtualservice rollouts-mesh-canary -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"
echo "VirtualService: ${weights:-unknown}"
echo "Sampling ${REQUESTS} requests through https://${host}/color"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for ((i=1; i<=REQUESTS; i++)); do
  body="$(curl -sk --connect-timeout 5 --max-time 10 "https://${host}/color" || true)"
  normalized="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alpha:]')"
  case "$normalized" in
    *blue*) echo blue >> "$tmp" ;;
    *yellow*) echo yellow >> "$tmp" ;;
    *) echo unknown >> "$tmp" ;;
  esac
done

echo
sort "$tmp" | uniq -c | awk -v n="$REQUESTS" '{printf "%8d  %-8s %6.2f%%\n", $1, $2, (100*$1/n)}'
echo
echo "The observed sample is statistical; it will approach the VirtualService weights as REQUESTS increases."
