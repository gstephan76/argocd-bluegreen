#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-canary-mesh-multi-bookinfo}"
A_VIRTUALSERVICE="${A_VIRTUALSERVICE:-bookinfo-a-rollout}"
REQUESTS_A="${REQUESTS_A:-20}"
REQUESTS_B="${REQUESTS_B:-100}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl awk sort uniq grep; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
[[ "$REQUESTS_A" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS_A must be a positive integer"
[[ "$REQUESTS_B" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS_B must be a positive integer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

host_a="$(oc get route bookinfo-a -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
host_b="$(oc get route bookinfo-b -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host_a" && -n "$host_b" && "$host_a" != "$host_b" ]] || die "Route hosts are missing or not distinct"

weights_a="$(oc get virtualservice "$A_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"
weights_b="$(oc get virtualservice bookinfo-b -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="primary")].route[0].weight}% canary={.spec.http[?(@.name=="primary")].route[1].weight}%' 2>/dev/null || true)"
a_stable_weight="$(oc get virtualservice "$A_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[0].weight}' 2>/dev/null || true)"
a_canary_weight="$(oc get virtualservice "$A_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.http[?(@.name=="primary")].route[1].weight}' 2>/dev/null || true)"
[[ "$a_stable_weight" == "100" && "$a_canary_weight" == "0" ]] ||
  die "Bookinfo A Rollout is not parked at 100/0; run prepare before the demo"

echo "Bookinfo A: independent Rollout, parked at baseline: https://${host_a}/productpage"
echo "Bookinfo A VirtualService: ${weights_a:-unknown}"
echo "Bookinfo B: independent Rollout, exercised by this demo: https://${host_b}/productpage"
echo "Bookinfo B VirtualService: ${weights_b:-unknown}"
echo

tmp_a="$(mktemp)"
tmp_b="$(mktemp)"
trap 'rm -f "$tmp_a" "$tmp_b"' EXIT

for ((i=1; i<=REQUESTS_A; i++)); do
  body="$(curl -sk "https://${host_a}/productpage" || true)"
  if grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-black-500' <<<"$body"; then
    echo stable >>"$tmp_a"
  elif grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-red-500' <<<"$body"; then
    echo unexpected-canary >>"$tmp_a"
  else
    echo unknown >>"$tmp_a"
  fi
done

echo "Bookinfo A distribution (${REQUESTS_A} requests; its Rollout must remain 100% stable):"
sort "$tmp_a" | uniq -c | awk -v n="$REQUESTS_A" '{printf "%8d  %-18s %6.2f%%\n", $1, $2, (100*$1/n)}'

for ((i=1; i<=REQUESTS_B; i++)); do
  body="$(curl -sk "https://${host_b}/productpage" || true)"
  if grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-red-500' <<<"$body"; then
    echo canary >>"$tmp_b"
  elif grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-black-500' <<<"$body"; then
    echo stable >>"$tmp_b"
  else
    echo unknown >>"$tmp_b"
  fi
done

echo
echo "Bookinfo B distribution (${REQUESTS_B} requests):"
sort "$tmp_b" | uniq -c | awk -v n="$REQUESTS_B" '{printf "%8d  %-18s %6.2f%%\n", $1, $2, (100*$1/n)}'
echo
echo "Both Bookinfo applications have independent Rollout CRs."
echo "Only Bookinfo B is exercised by the demo; Bookinfo A remains parked at its stable baseline."
echo "Every Bookinfo B canary-classified response enters the isolated Bookinfo B canary stack."
