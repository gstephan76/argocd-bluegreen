#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
DEMO_PAUSE_SECONDS="${DEMO_PAUSE_SECONDS:-2}"

echo "============================================================"
echo " KEDA demo - Red Hat OpenShift 4.20+"
echo " Prometheus backlog -> KEDA -> HPA -> worker Deployment"
echo "============================================================"
echo

echo "[1/6] Install/reconcile Red Hat Custom Metrics Autoscaler"
"${ROOT_DIR}/scripts/install-keda.sh"

echo
echo "[2/6] Deploy/reconcile metric source, auth, ScaledObject and worker"
"${ROOT_DIR}/scripts/deploy-keda.sh"

echo
echo "[3/6] Baseline: backlog 0 -> workers 0"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0
sleep "${DEMO_PAUSE_SECONDS}"

echo
echo "[4/6] Load: backlog 50 -> workers 5"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 50
sleep "${DEMO_PAUSE_SECONDS}"

echo
echo "[5/6] Drain: backlog 5 -> workers 1"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 5
sleep "${DEMO_PAUSE_SECONDS}"

echo
echo "[6/6] Idle: backlog 0 -> workers 0"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0

echo
echo "============================================================"
echo " KEDA demonstration completed successfully"
echo "============================================================"
echo
oc get scaledobject,hpa,deployment,pod -n "${APP_NAMESPACE}"
echo
echo "Change the signal manually with:"
echo "  ${ROOT_DIR}/scripts/set-keda-backlog.sh <value>"
echo
echo "Cleanup demo resources with:"
echo "  ${ROOT_DIR}/scripts/cleanup-keda.sh"
