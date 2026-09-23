#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-600}"
SERVING_TIMEOUT="${SERVING_TIMEOUT:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

if oc get crd services.serving.knative.dev >/dev/null 2>&1 &&
   oc get knativeserving knative-serving -n knative-serving >/dev/null 2>&1; then
  ready="$(oc get knativeserving knative-serving \
    -n knative-serving \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${ready}" == "True" ]]; then
    echo "Knative Serving is already installed and Ready."
    oc get knativeserving knative-serving -n knative-serving
    exit 0
  fi
fi

echo "==> Installing or reconciling the OpenShift Serverless Operator"
oc apply -f "${ROOT_DIR}/platform/serverless-subscription.yaml"

echo "==> Waiting for the KnativeServing CRD"
deadline=$((SECONDS + OPERATOR_TIMEOUT))
while (( SECONDS < deadline )); do
  oc get crd knativeservings.operator.knative.dev >/dev/null 2>&1 && break
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get csv -n openshift-serverless || true
  die "Timed out waiting for knativeservings.operator.knative.dev"
}

echo "==> Installing or reconciling Knative Serving"
oc apply -f "${ROOT_DIR}/platform/knative-serving.yaml"

if ! oc wait --for=condition=Ready knativeserving/knative-serving \
  -n knative-serving \
  --timeout="${SERVING_TIMEOUT}s"; then
  oc get knativeserving knative-serving -n knative-serving -o yaml || true
  oc get pods -n knative-serving -o wide || true
  die "Knative Serving did not become Ready"
fi

echo
echo "Knative Serving is Ready."
oc get knativeserving knative-serving -n knative-serving
oc get pods -n knative-serving
