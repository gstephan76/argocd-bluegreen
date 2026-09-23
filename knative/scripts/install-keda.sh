#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_TIMEOUT="${OPERATOR_TIMEOUT:-600}"
KEDA_TIMEOUT="${KEDA_TIMEOUT:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

ocp_version="$(oc get clusterversion version \
  -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
[[ "${ocp_version}" =~ ^([0-9]+)\.([0-9]+) ]] || \
  die "Could not determine the OpenShift cluster version"

major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
if (( major < 4 || (major == 4 && minor < 20) )); then
  die "This demo requires OpenShift Container Platform 4.20+; cluster reports ${ocp_version}"
fi

echo "==> OpenShift ${ocp_version} satisfies the 4.20+ demo requirement"

if oc get crd scaledobjects.keda.sh >/dev/null 2>&1 &&
   oc get kedacontroller keda -n openshift-keda >/dev/null 2>&1 &&
   oc get deployment keda-operator -n openshift-keda >/dev/null 2>&1; then
  echo "==> Red Hat Custom Metrics Autoscaler / KEDA is already installed"
  oc get kedacontroller keda -n openshift-keda
  oc get deployment keda-operator keda-metrics-apiserver -n openshift-keda
  exit 0
fi

echo "==> Installing/reconciling the Red Hat Custom Metrics Autoscaler Operator"
oc apply -f "${ROOT_DIR}/keda/platform/custom-metrics-autoscaler.yaml"

echo "==> Waiting for KEDA CRDs"
deadline=$((SECONDS + OPERATOR_TIMEOUT))
while (( SECONDS < deadline )); do
  if oc get crd scaledobjects.keda.sh >/dev/null 2>&1 &&
     oc get crd triggerauthentications.keda.sh >/dev/null 2>&1 &&
     oc get crd kedacontrollers.keda.sh >/dev/null 2>&1; then
    break
  fi
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get subscription,csv -n openshift-keda || true
  die "Timed out waiting for Custom Metrics Autoscaler CRDs"
}

# Supported OCP 4.20+ Custom Metrics Autoscaler releases automatically
# create KedaController/keda. Do not create an alternate controller here.
echo "==> Waiting for the automatically-created KedaController"
deadline=$((SECONDS + KEDA_TIMEOUT))
while (( SECONDS < deadline )); do
  oc get kedacontroller keda -n openshift-keda >/dev/null 2>&1 && break
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get subscription,csv -n openshift-keda || true
  oc get kedacontroller -n openshift-keda || true
  die "Timed out waiting for KedaController/keda"
}

echo "==> Waiting for KEDA data-plane deployments"
deadline=$((SECONDS + KEDA_TIMEOUT))
while (( SECONDS < deadline )); do
  all_ready=1
  for d in keda-operator keda-metrics-apiserver; do
    count="$(oc get deployment "$d" -n openshift-keda \
      -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ "${count:-0}" -lt 1 ]]; then
      all_ready=0
      break
    fi
  done
  [[ "${all_ready}" == "1" ]] && break
  sleep "${POLL_SECONDS}"
done
(( SECONDS < deadline )) || {
  oc get all -n openshift-keda || true
  die "Timed out waiting for KEDA deployments"
}

echo
echo "Custom Metrics Autoscaler / KEDA is Ready."
oc get kedacontroller keda -n openshift-keda
oc get deployment keda-operator keda-metrics-apiserver -n openshift-keda
