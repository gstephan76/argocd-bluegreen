#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
ROUTE_NAME="${ROUTE_NAME:-rollouts-mesh-canary-demo}"
MESH_INGRESS_NAMESPACE="${MESH_INGRESS_NAMESPACE:-}"
REQUESTS="${REQUESTS:-100}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl awk sort uniq; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
[[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS must be a positive integer"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

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
