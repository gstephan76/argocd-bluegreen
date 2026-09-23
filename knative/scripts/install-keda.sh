#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-600}"
KEDA_TIMEOUT="${KEDA_TIMEOUT:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

if oc get crd scaledobjects.keda.sh >/dev/null 2>&1 &&
   oc get deployment keda-operator -n openshift-keda >/dev/null 2>&1; then
  echo "OpenShift Custom Metrics Autoscaler / KEDA is already installed."
  oc get deployment -n openshift-keda
  exit 0
fi

echo "==> Installing the Red Hat Custom Metrics Autoscaler Operator"
oc apply -f "${ROOT_DIR}/keda/platform/custom-metrics-autoscaler.yaml"

echo "==> Waiting for KEDA CRDs"
deadline=$((SECONDS + OPERATOR_TIMEOUT))
while (( SECONDS < deadline )); do
  if oc get crd scaledobjects.keda.sh >/dev/null 2>&1 &&
     oc get crd kedacontrollers.keda.sh >/dev/null 2>&1; then
    break
  fi
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get subscription,csv -n openshift-keda || true
  die "Timed out waiting for Custom Metrics Autoscaler CRDs"
}

# OCP 4.22 creates KedaController automatically. Keep a fallback for clusters
# where the operator is present but the controller instance is absent.
if ! oc get kedacontroller keda -n openshift-keda >/dev/null 2>&1; then
  echo "==> KedaController was not auto-created; applying the repository fallback"
  oc apply -f "${ROOT_DIR}/keda/platform/keda-controller.yaml"
fi

echo "==> Waiting for KEDA data-plane deployments"
deadline=$((SECONDS + KEDA_TIMEOUT))
while (( SECONDS < deadline )); do
  available=0
  for d in keda-operator keda-metrics-apiserver keda-admission; do
    count="$(oc get deployment "$d" -n openshift-keda \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    [[ "${count:-0}" -ge 1 ]] || continue 2
  done
  available=1
  [[ "${available}" == "1" ]] && break
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get all -n openshift-keda || true
  die "Timed out waiting for KEDA deployments"
}

echo
echo "Custom Metrics Autoscaler / KEDA is Ready."
oc get kedacontroller -n openshift-keda
oc get deployment -n openshift-keda
