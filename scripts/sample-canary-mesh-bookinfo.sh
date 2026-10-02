#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-bookinfo}"
APP_NAME="${APP_NAME:-canary-mesh-bookinfo}"
REQUESTS="${REQUESTS:-100}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl awk sort uniq grep; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
[[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS must be a positive integer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Route host is empty"
weights="$(oc get virtualservice "$APP_NAME" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"

echo "VirtualService: ${weights:-unknown}"
echo "Sampling ${REQUESTS} complete Bookinfo requests through https://${host}/productpage"
echo "stable=v2 black-star reviews; canary=v3 red-star reviews"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for ((i=1; i<=REQUESTS; i++)); do
  body="$(curl -sk "https://${host}/productpage" || true)"
  if grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-red-500' <<<"$body"; then
    echo canary >>"$tmp"
  elif grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-black-500' <<<"$body"; then
    echo stable >>"$tmp"
  else
    echo unknown >>"$tmp"
  fi
done

echo
sort "$tmp" | uniq -c | awk -v n="$REQUESTS" '{printf "%8d  %-8s %6.2f%%\n", $1, $2, (100*$1/n)}'
echo
echo "Every canary-classified response traversed productpage-canary -> details-canary + reviews-canary -> ratings-canary."
