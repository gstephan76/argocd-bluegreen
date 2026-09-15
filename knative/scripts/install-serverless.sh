#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-600}"
SERVING_TIMEOUT="${SERVING_TIMEOUT:-600}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required." >&2; exit 1; }
oc whoami >/dev/null

echo "==> Installing or reconciling the OpenShift Serverless Operator"
oc apply -f "${ROOT_DIR}/platform/serverless-subscription.yaml"

echo "==> Waiting for the KnativeServing CRD"
end=$((SECONDS + OPERATOR_TIMEOUT))
until oc get crd knativeservings.operator.knative.dev >/dev/null 2>&1; do
  if (( SECONDS >= end )); then
    echo "ERROR: timed out waiting for knativeservings.operator.knative.dev" >&2
    oc get csv -n openshift-serverless || true
    exit 1
  fi
  sleep 5
done

echo "==> Installing or reconciling Knative Serving"
oc apply -f "${ROOT_DIR}/platform/knative-serving.yaml"

if ! oc wait --for=condition=Ready knativeserving/knative-serving \
  -n knative-serving --timeout="${SERVING_TIMEOUT}s"; then
  echo "ERROR: Knative Serving did not become Ready." >&2
  oc get knativeserving knative-serving -n knative-serving -o yaml || true
  oc get pods -n knative-serving || true
  exit 1
fi

echo "==> Knative Serving is Ready"
oc get knativeserving knative-serving -n knative-serving
oc get pods -n knative-serving
