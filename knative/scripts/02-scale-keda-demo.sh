#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
HOLD_SECONDS="${HOLD_SECONDS:-3}"

die(){ echo "ERROR: $*" >&2; exit 1; }

command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

oc get scaledobject keda-async-worker \
  -n "${APP_NAMESPACE}" >/dev/null 2>&1 || \
  die "KEDA demo is not deployed. Run scripts/01-deploy-keda-demo.sh first."

echo "============================================================"
echo " STEP 2/2 - KEDA scale out and scale in"
echo "============================================================"

echo
echo "Baseline: backlog 0 -> workers 0"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0
sleep "${HOLD_SECONDS}"

echo
echo "SCALE OUT: backlog 50 -> workers 5"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 50
sleep "${HOLD_SECONDS}"

echo
echo "SCALE IN: backlog 5 -> workers 1"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 5
sleep "${HOLD_SECONDS}"

echo
echo "SCALE TO ZERO: backlog 0 -> workers 0"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0

echo
echo "============================================================"
echo " STEP 2 complete"
echo " Observed sequence: 0 -> 5 -> 1 -> 0 workers"
echo "============================================================"
echo
oc get scaledobject,hpa,deployment,pod \
  -n "${APP_NAMESPACE}"
