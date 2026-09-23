#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
ZERO_TIMEOUT="${ZERO_TIMEOUT:-180}"
WAKE_TIMEOUT="${WAKE_TIMEOUT:-120}"
CURL_INSECURE="${CURL_INSECURE:-0}"
MODE="${1:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

case "${MODE}" in
  ""|--scale-to-zero) ;;
  *) die "Usage: $0 [--scale-to-zero]" ;;
esac

curl_args=(--fail --silent --show-error --location)
[[ "${CURL_INSECURE}" != "1" ]] || curl_args+=(--insecure)

URL="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"
READY="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
REVISION="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.latestReadyRevisionName}')"
[[ "${READY}" == "True" ]] || die "${SERVICE_NAME} is not Ready"

echo "==> Knative Serving objects"
oc get ksvc,configuration,revision,route -n "${APP_NAMESPACE}"

echo
echo "==> Traffic targets"
oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" \
  -o jsonpath='{range .status.traffic[*]}{.percent}{"% -> "}{.revisionName}{" tag="}{.tag}{" url="}{.url}{"\n"}{end}'

echo
echo "==> HTTP check: ${URL}"
body="$(curl "${curl_args[@]}" "${URL}")"
printf '%s' "${body}" | grep -q 'Knative HTTPD Demo'
printf '%s' "${body}" | grep -Eq 'Revision V[12]'
echo "HTTP response contains the expected Knative revision page."

[[ "${MODE}" == "--scale-to-zero" ]] || exit 0

running_revision_pods() {
  oc get pods \
    -n "${APP_NAMESPACE}" \
    -l "serving.knative.dev/revision=${REVISION}" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

echo
echo "==> Waiting for ${REVISION} to scale to zero"
echo "Do not refresh the Service URL while waiting."
deadline=$((SECONDS + ZERO_TIMEOUT))
while (( SECONDS < deadline )); do
  count="$(running_revision_pods)"
  if [[ "${count}" == "0" ]]; then
    echo "Scale-to-zero confirmed."
    break
  fi
  printf '    running pods: %s\n' "${count}"
  sleep 5
done
[[ "$(running_revision_pods)" == "0" ]] || die "Revision did not scale to zero"

echo
echo "==> Sending cold activation request"
curl "${curl_args[@]}" "${URL}" >/dev/null

deadline=$((SECONDS + WAKE_TIMEOUT))
while (( SECONDS < deadline )); do
  count="$(running_revision_pods)"
  if (( count > 0 )); then
    echo "Cold activation confirmed: ${count} running pod(s)."
    exit 0
  fi
  sleep 2
done

die "No revision pod appeared after the activation request"
