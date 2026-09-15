#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
ZERO_TIMEOUT="${ZERO_TIMEOUT:-180}"
WAKE_TIMEOUT="${WAKE_TIMEOUT:-120}"
CURL_INSECURE="${CURL_INSECURE:-0}"
MODE="${1:-}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
oc whoami >/dev/null

curl_args=(--fail --silent --show-error --location)
if [[ "${CURL_INSECURE}" == "1" ]]; then
  curl_args+=(--insecure)
fi

URL="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"
READY="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"

if [[ "${READY}" != "True" ]]; then
  echo "ERROR: ${SERVICE_NAME} is not Ready (Ready=${READY:-unknown})." >&2
  exit 1
fi

echo "==> Knative Service"
oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}"

echo
echo "==> Revisions"
oc get revision -n "${APP_NAMESPACE}" -l "serving.knative.dev/service=${SERVICE_NAME}"

echo
echo "==> HTTP check: ${URL}"
body="$(curl "${curl_args[@]}" "${URL}")"
if command -v rg >/dev/null 2>&1; then
  printf '%s' "${body}" | rg -q 'Knative HTTPD Demo'
else
  printf '%s' "${body}" | grep -q 'Knative HTTPD Demo'
fi
echo "HTTP response contains the expected Knative HTTPD page."

if [[ "${MODE}" != "--scale-to-zero" ]]; then
  exit 0
fi

running_pods() {
  oc get pods -n "${APP_NAMESPACE}" \
    -l "serving.knative.dev/service=${SERVICE_NAME}" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l | tr -d ' '
}

echo
echo "==> Waiting for the revision to scale to zero (timeout: ${ZERO_TIMEOUT}s)"
end=$((SECONDS + ZERO_TIMEOUT))
while (( SECONDS < end )); do
  count="$(running_pods)"
  if [[ "${count}" == "0" ]]; then
    echo "Scale-to-zero confirmed: no running revision pods."
    break
  fi
  printf '  running revision pods: %s\n' "${count}"
  sleep 5
done

if [[ "$(running_pods)" != "0" ]]; then
  echo "ERROR: revision did not scale to zero within ${ZERO_TIMEOUT}s." >&2
  oc get pods -n "${APP_NAMESPACE}" -l "serving.knative.dev/service=${SERVICE_NAME}" || true
  exit 1
fi

echo
echo "==> Sending a request to reactivate the service"
curl "${curl_args[@]}" "${URL}" >/dev/null

end=$((SECONDS + WAKE_TIMEOUT))
while (( SECONDS < end )); do
  count="$(running_pods)"
  if (( count > 0 )); then
    echo "Cold activation confirmed: revision pod count is ${count}."
    exit 0
  fi
  sleep 2
done

echo "ERROR: no running revision pod appeared within ${WAKE_TIMEOUT}s." >&2
exit 1
