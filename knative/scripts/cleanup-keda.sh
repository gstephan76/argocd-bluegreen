#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
MODE="${1:-}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc is required" >&2; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in to OpenShift" >&2; exit 1; }

echo "==> Removing KEDA companion demo resources"
oc delete -k "${ROOT_DIR}/keda/app" --ignore-not-found

if [[ "${MODE}" == "--platform" ]]; then
  echo "WARNING: removing the Custom Metrics Autoscaler affects every KEDA workload on this cluster."
  oc delete kedacontroller keda -n openshift-keda --ignore-not-found || true
  oc delete subscription openshift-custom-metrics-autoscaler-operator \
    -n openshift-keda --ignore-not-found || true
  oc delete operatorgroup openshift-keda -n openshift-keda --ignore-not-found || true
  oc delete namespace openshift-keda --ignore-not-found || true
fi
