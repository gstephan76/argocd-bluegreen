#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
CURL_INSECURE="${CURL_INSECURE:-0}"
SAMPLES="${SAMPLES:-20}"
CANDIDATE_PERCENT="${1:-50}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

[[ "${CANDIDATE_PERCENT}" =~ ^[0-9]+$ ]] || die "Percentage must be an integer"
(( CANDIDATE_PERCENT >= 1 && CANDIDATE_PERCENT <= 99 )) || die "Percentage must be 1..99"
current_percent=$((100 - CANDIDATE_PERCENT))

current_revision="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.traffic[?(@.tag=="current")].revisionName}')"
candidate_revision="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}')"
[[ -n "${current_revision}" && -n "${candidate_revision}" ]] || \
  die "Run scripts/new-revision.sh first"

patch="$(printf \
  '{"spec":{"traffic":[{"revisionName":"%s","percent":%d,"tag":"current"},{"revisionName":"%s","percent":%d,"tag":"candidate"}]}}' \
  "${current_revision}" "${current_percent}" "${candidate_revision}" "${CANDIDATE_PERCENT}")"

echo "==> Knative traffic split: V1 ${current_percent}% / V2 ${CANDIDATE_PERCENT}%"
oc patch ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" --type=merge -p "${patch}" >/dev/null
oc wait --for=condition=Ready "ksvc/${SERVICE_NAME}" -n "${APP_NAMESPACE}" --timeout="${READY_TIMEOUT}s"

url="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"
curl_args=(--fail --silent --show-error --location)
[[ "${CURL_INSECURE}" != "1" ]] || curl_args+=(--insecure)

v1=0; v2=0; other=0
for _ in $(seq 1 "${SAMPLES}"); do
  body="$(curl "${curl_args[@]}" "${url}")"
  if [[ "${body}" == *"Revision V1"* ]]; then
    v1=$((v1 + 1))
  elif [[ "${body}" == *"Revision V2"* ]]; then
    v2=$((v2 + 1))
  else
    other=$((other + 1))
  fi
done

echo
oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{range .status.traffic[*]}{.percent}{"% -> "}{.revisionName}{" tag="}{.tag}{"\n"}{end}'
echo "Observed ${SAMPLES} requests: V1=${v1} V2=${v2} other=${other}"
echo "Small samples are not expected to match the configured percentage exactly."
