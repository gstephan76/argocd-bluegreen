#!/usr/bin/env bash
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
MODE="${1:-}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required." >&2; exit 1; }
oc whoami >/dev/null

echo "==> Deleting demo namespace ${APP_NAMESPACE}"
oc delete namespace "${APP_NAMESPACE}" --ignore-not-found

if [[ "${MODE}" == "--platform" ]]; then
  echo "==> Removing Knative Serving and OpenShift Serverless Operator resources"
  oc delete knativeserving knative-serving -n knative-serving --ignore-not-found || true
  oc delete namespace knative-serving --ignore-not-found || true
  oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found || true
  oc delete operatorgroup serverless-operators -n openshift-serverless --ignore-not-found || true
  oc delete namespace openshift-serverless --ignore-not-found || true
fi
