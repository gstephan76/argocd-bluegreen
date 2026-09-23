#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
CURL_INSECURE="${CURL_INSECURE:-0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

candidate="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' 2>/dev/null || true)"
[[ -n "${candidate}" ]] || candidate="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true)"
[[ -n "${candidate}" ]] || die "No candidate Revision found"

patch="$(printf '{"spec":{"traffic":[{"revisionName":"%s","percent":100}]}}' "${candidate}")"
echo "==> Promoting ${candidate} to 100%"
oc patch ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" --type=merge -p "${patch}" >/dev/null
oc wait --for=condition=Ready "ksvc/${SERVICE_NAME}" -n "${APP_NAMESPACE}" --timeout="${READY_TIMEOUT}s"

url="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"
curl_args=(--fail --silent --show-error --location)
[[ "${CURL_INSECURE}" != "1" ]] || curl_args+=(--insecure)
curl "${curl_args[@]}" "${url}" | grep -q 'Revision V2'

echo
echo "V2 is serving 100% of normal traffic."
echo "Revision: ${candidate}"
echo "URL     : ${url}"
