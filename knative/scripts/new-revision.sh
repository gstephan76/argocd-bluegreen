#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
CURL_INSECURE="${CURL_INSECURE:-0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl date; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

curl_args=(--fail --silent --show-error --location)
[[ "${CURL_INSECURE}" != "1" ]] || curl_args+=(--insecure)

ready="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "${ready}" == "True" ]] || die "Deploy V1 first with scripts/deploy.sh"

current_revision="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.latestReadyRevisionName}')"
main_url="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.url}')"

curl "${curl_args[@]}" "${main_url}" | grep -q 'Revision V1' || \
  die "Main URL is not serving V1; reset with scripts/deploy.sh"

echo "==> Pinning V1 to 100% and reserving a tagged 0% candidate target"
traffic_patch="$(printf \
  '{"spec":{"traffic":[{"revisionName":"%s","percent":100,"tag":"current"},{"latestRevision":true,"percent":0,"tag":"candidate"}]}}' \
  "${current_revision}")"
oc patch ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" --type=merge -p "${traffic_patch}" >/dev/null

trigger="v2-$(date -u +%Y%m%dT%H%M%SZ)"
echo "==> Creating V2 Revision (${trigger})"
template_patch="$(printf \
  '{"spec":{"template":{"metadata":{"annotations":{"demo.knative.dev/version":"%s"}},"spec":{"volumes":[{"name":"page","configMap":{"name":"httpd-page-v2","items":[{"key":"index.html","path":"index.html"}]}}]}}}}' \
  "${trigger}")"
oc patch ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" --type=merge -p "${template_patch}" >/dev/null

deadline=$((SECONDS + READY_TIMEOUT))
candidate_revision=""
while (( SECONDS < deadline )); do
  ready="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  candidate_revision="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true)"
  printf '    ready=%s current=%s candidate=%s\n' \
    "${ready:-unknown}" "${current_revision}" "${candidate_revision:-pending}"
  [[ "${ready}" == "True" &&
     -n "${candidate_revision}" &&
     "${candidate_revision}" != "${current_revision}" ]] && break
  sleep 3
done
(( SECONDS < deadline )) || die "Timed out waiting for V2"

candidate_url="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{.status.traffic[?(@.tag=="candidate")].url}')"
[[ -n "${candidate_url}" ]] || die "Candidate URL was not created"

curl "${curl_args[@]}" "${main_url}" | grep -q 'Revision V1'
curl "${curl_args[@]}" "${candidate_url}" | grep -q 'Revision V2'

echo
echo "V2 candidate is Ready with 0% of normal traffic."
echo "V1 Revision : ${current_revision}"
echo "V2 Revision : ${candidate_revision}"
echo "Main URL    : ${main_url}"
echo "Candidate   : ${candidate_url}"
echo
echo "Next:"
echo "  scripts/split-traffic.sh 50"
