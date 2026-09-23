#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

oc get crd services.serving.knative.dev >/dev/null 2>&1 || {
  echo "Knative Serving is not installed. Run:" >&2
  echo "  ${ROOT_DIR}/scripts/install-serverless.sh" >&2
  exit 1
}

echo "==> Applying Knative demo resources"
oc apply -k "${ROOT_DIR}/app"

echo "==> Resetting the Service template to V1 and traffic to 100% latest"
oc patch ksvc "${SERVICE_NAME}" \
  -n "${APP_NAMESPACE}" \
  --type=merge \
  -p '{"spec":{"template":{"metadata":{"annotations":{"demo.knative.dev/version":"v1"}},"spec":{"volumes":[{"name":"page","configMap":{"name":"httpd-page-v1","items":[{"key":"index.html","path":"index.html"}]}}]}},"traffic":[{"latestRevision":true,"percent":100}]}}' \
  >/dev/null

if ! oc wait --for=condition=Ready "ksvc/${SERVICE_NAME}" \
  -n "${APP_NAMESPACE}" \
  --timeout="${READY_TIMEOUT}s"; then
  oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o yaml || true
  oc get revision,pod -n "${APP_NAMESPACE}" -o wide || true
  die "Knative Service did not become Ready"
fi

URL="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"
REVISION="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.latestReadyRevisionName}')"

echo
echo "V1 baseline is Ready."
echo "Revision: ${REVISION}"
echo "URL     : ${URL}"
echo
echo "Verify:"
echo "  ${ROOT_DIR}/scripts/verify.sh"
echo
echo "Scale-to-zero / cold activation:"
echo "  ${ROOT_DIR}/scripts/verify.sh --scale-to-zero"
echo
echo "Create a V2 candidate:"
echo "  ${ROOT_DIR}/scripts/new-revision.sh"
