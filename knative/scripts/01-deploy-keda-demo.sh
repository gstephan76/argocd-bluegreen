#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"

echo "============================================================"
echo " STEP 1/2 - Declarative KEDA deployment"
echo "============================================================"
echo
echo "KEDA policy to show during the demo:"
echo "  ${ROOT_DIR}/keda/app/scaledobject.yaml"
echo
echo "Declarative application deployment:"
echo "  oc apply -k ${ROOT_DIR}/keda/app"
echo

echo "==> Installing/reconciling Red Hat Custom Metrics Autoscaler"
"${ROOT_DIR}/scripts/install-keda.sh"

echo
echo "==> Deploying the KEDA application"
echo "    This reuses the same OpenShift user-workload Prometheus/Thanos"
echo "    stack already used by the Canary demo."
"${ROOT_DIR}/scripts/deploy-keda.sh"

echo
echo "============================================================"
echo " STEP 1 complete"
echo "============================================================"
echo
echo "Expected baseline: demo_async_backlog=0 and worker replicas=0"
oc get scaledobject,hpa,deployment,pod \
  -n "${APP_NAMESPACE}"

echo
echo "Next:"
echo "  ${ROOT_DIR}/scripts/02-scale-keda-demo.sh"
