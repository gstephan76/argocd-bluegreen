#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required." >&2; exit 1; }
oc whoami >/dev/null

if ! oc get crd services.serving.knative.dev >/dev/null 2>&1; then
  cat >&2 <<EOF2
ERROR: Knative Serving is not installed.
Run:
  ${ROOT_DIR}/scripts/install-serverless.sh
EOF2
  exit 1
fi

echo "==> Deploying the Knative HTTPD single-page application"
oc apply -k "${ROOT_DIR}/app"

echo "==> Waiting for Knative Service ${SERVICE_NAME}"
if ! oc wait --for=condition=Ready "ksvc/${SERVICE_NAME}" \
  -n "${APP_NAMESPACE}" --timeout="${READY_TIMEOUT}s"; then
  echo "ERROR: Knative Service did not become Ready." >&2
  oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o yaml || true
  oc get revision -n "${APP_NAMESPACE}" || true
  oc get pods -n "${APP_NAMESPACE}" -o wide || true
  exit 1
fi

URL="$(oc get ksvc "${SERVICE_NAME}" -n "${APP_NAMESPACE}" -o jsonpath='{.status.url}')"

echo
echo "Deployment complete."
echo "URL: ${URL}"
echo
echo "Verify it with:"
echo "  ${ROOT_DIR}/scripts/verify.sh"
echo
echo "Test scale-to-zero and cold activation with:"
echo "  ${ROOT_DIR}/scripts/verify.sh --scale-to-zero"
