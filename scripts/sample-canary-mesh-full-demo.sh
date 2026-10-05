#!/usr/bin/env bash
set -Eeuo pipefail
NAMESPACE="${NAMESPACE:-canary-mesh-full-demo}"
DEMO_ROUTE="${DEMO_ROUTE:-full-demo}"
SHARED_VIRTUALSERVICE="${SHARED_VIRTUALSERVICE:-full-demo-router}"
TARGET_HEADER="${TARGET_HEADER:-x-bookinfo-target}"
A_HEADER_VALUE="${A_HEADER_VALUE:-a}"
B_HEADER_VALUE="${B_HEADER_VALUE:-b}"
REQUESTS_A="${REQUESTS_A:-20}"
REQUESTS_B="${REQUESTS_B:-100}"
die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl awk sort uniq grep; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
[[ "$REQUESTS_A" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS_A must be a positive integer"
[[ "$REQUESTS_B" =~ ^[1-9][0-9]*$ ]] || die "REQUESTS_B must be a positive integer"
host="$(oc get route "$DEMO_ROUTE" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
[[ -n "$host" ]] || die "Shared Route host is missing"
a_weights="$(oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="bookinfo-a-primary")].route[0].weight}% canary={.spec.http[?(@.name=="bookinfo-a-primary")].route[1].weight}%')"
b_weights="$(oc get virtualservice "$SHARED_VIRTUALSERVICE" -n "$NAMESPACE" -o jsonpath='stable={.spec.http[?(@.name=="bookinfo-b-primary")].route[0].weight}% canary={.spec.http[?(@.name=="bookinfo-b-primary")].route[1].weight}%')"
echo "Shared URL: https://${host}/productpage"
echo "Bookinfo A selector: ${TARGET_HEADER}: ${A_HEADER_VALUE} (${a_weights})"
echo "Bookinfo B selector: ${TARGET_HEADER}: ${B_HEADER_VALUE} (${b_weights})"
tmp_a="$(mktemp)"; tmp_b="$(mktemp)"; trap 'rm -f "$tmp_a" "$tmp_b"' EXIT
for ((i=1;i<=REQUESTS_A;i++)); do
  body="$(curl -sk -H "${TARGET_HEADER}: ${A_HEADER_VALUE}" "https://${host}/productpage" || true)"
  if grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-black-500' <<<"$body"; then echo stable >>"$tmp_a";
  elif grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-red-500' <<<"$body"; then echo unexpected-canary >>"$tmp_a";
  else echo unknown >>"$tmp_a"; fi
done
for ((i=1;i<=REQUESTS_B;i++)); do
  body="$(curl -sk -H "${TARGET_HEADER}: ${B_HEADER_VALUE}" "https://${host}/productpage" || true)"
  if grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-red-500' <<<"$body"; then echo canary >>"$tmp_b";
  elif grep -q 'glyphicon glyphicon-star' <<<"$body" && grep -q 'text-black-500' <<<"$body"; then echo stable >>"$tmp_b";
  else echo unknown >>"$tmp_b"; fi
done
echo; echo "Bookinfo A distribution (${REQUESTS_A} requests; must remain stable):"
sort "$tmp_a" | uniq -c | awk -v n="$REQUESTS_A" '{printf "%8d  %-18s %6.2f%%\n",$1,$2,100*$1/n}'
echo; echo "Bookinfo B distribution (${REQUESTS_B} requests):"
sort "$tmp_b" | uniq -c | awk -v n="$REQUESTS_B" '{printf "%8d  %-18s %6.2f%%\n",$1,$2,100*$1/n}'
