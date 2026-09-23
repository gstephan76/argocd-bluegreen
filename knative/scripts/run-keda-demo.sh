#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== KEDA companion demo ==="
echo
echo "0 backlog -> 0 workers"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0

echo
echo "50 backlog -> 5 workers (target 10 units/worker)"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 50

echo
echo "5 backlog -> 1 worker"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 5

echo
echo "0 backlog -> scale to zero"
"${ROOT_DIR}/scripts/set-keda-backlog.sh" 0

echo
echo "Final state:"
oc get scaledobject,hpa,deployment,pod -n "${APP_NAMESPACE:-knative-httpd}"
