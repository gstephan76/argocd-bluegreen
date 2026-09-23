#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

echo "==> Preparing Metric-AI demo through the robust pre-flight"
bash scripts/preflight-metric-ai-demo.sh --remediate

host="$(
  oc get route "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true
)"

echo
echo "Metric-AI demo is ready."
[[ -n "$host" ]] && echo "Application: https://${host}"
echo
echo "Recommended presenter interface:"
echo "  ./scripts/run-metric-ai-demo.sh healthy"
echo "  ./scripts/run-metric-ai-demo.sh promote"
echo "  ./scripts/run-metric-ai-demo.sh failure"
