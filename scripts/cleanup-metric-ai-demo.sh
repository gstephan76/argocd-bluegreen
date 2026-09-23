#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
MODE="${1:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc not found"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

echo "==> Removing Argo CD Application"
oc delete applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  --ignore-not-found

echo "==> Removing demo namespace"
oc delete namespace "$NAMESPACE" --ignore-not-found

echo "==> Removing isolated Kubernetes AI agent"
oc delete deployment "$AGENT_NAME" -n "$ARGOCD_NAMESPACE" --ignore-not-found
oc delete service "$AGENT_NAME" -n "$ARGOCD_NAMESPACE" --ignore-not-found
oc delete serviceaccount "$AGENT_NAME" -n "$ARGOCD_NAMESPACE" --ignore-not-found
oc delete secret "$AGENT_NAME" -n "$ARGOCD_NAMESPACE" --ignore-not-found
oc delete secret metric-ai-github-bootstrap -n "$ARGOCD_NAMESPACE" --ignore-not-found

if [[ "$MODE" == "--platform" ]]; then
  existing="$(
    oc get rolloutmanager "$ROLLOUT_MANAGER" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{range .spec.plugins.metric[*]}{.name}{"\n"}{end}' \
      2>/dev/null || true
  )"

  if [[ "$existing" == "argoproj-labs/metric-ai" ]]; then
    echo "==> Removing metric-ai from RolloutManager"
    oc patch rolloutmanager "$ROLLOUT_MANAGER" \
      -n "$ARGOCD_NAMESPACE" \
      --type=json \
      -p='[{"op":"remove","path":"/spec/plugins/metric"}]'
  elif [[ -n "$existing" ]]; then
    echo "Metric plugin configuration contains other entries; leaving platform configuration unchanged."
  else
    echo "No metric plugin configured on RolloutManager."
  fi
fi

echo
echo "Cleanup complete."
