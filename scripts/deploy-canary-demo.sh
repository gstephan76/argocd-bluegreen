#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null || die "oc not found"
command -v git >/dev/null || die "git not found"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc get crd applications.argoproj.io >/dev/null
oc get crd rollouts.argoproj.io >/dev/null
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

echo "==> Applying Argo CD Application"
oc apply -f argocd/application-canary.yaml

echo "==> Waiting for Argo CD sync"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  printf '    sync=%s health=%s\n' "${sync:-unknown}" "${health:-unknown}"
  [[ "$sync" == "Synced" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for BLUE pods"
oc wait --for=condition=Ready pod -l app="$APP_NAME" -n "$NAMESPACE" --timeout="${TIMEOUT_SECONDS}s"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
echo
echo "Canary demo deployed: https://${host}"
echo "Next: bash scripts/start-canary-yellow.sh"
