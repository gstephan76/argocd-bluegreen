#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_APP="${ARGOCD_APP:-knative-httpd-demo}"
MODE="${1:-}"
FORCE_PLATFORM_CLEANUP="${FORCE_PLATFORM_CLEANUP:-0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

case "$MODE" in
  ""|--platform) ;;
  *) die "Usage: $0 [--platform]" ;;
esac

echo "==> Removing Knative Argo CD Application"
if oc get crd applications.argoproj.io >/dev/null 2>&1; then
  oc delete applications.argoproj.io "$ARGOCD_APP" \
    -n "$ARGOCD_NAMESPACE" \
    --ignore-not-found
fi

echo "==> Deleting demo namespace ${APP_NAMESPACE}"
oc delete namespace "$APP_NAMESPACE" --ignore-not-found

if [[ "$MODE" == "--platform" ]]; then
  if oc get crd services.serving.knative.dev >/dev/null 2>&1; then
    other_services="$(
      oc get ksvc -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' \
        2>/dev/null || true
    )"
  else
    other_services=""
  fi

  if [[ -n "$other_services" && "$FORCE_PLATFORM_CLEANUP" != "1" ]]; then
    echo "Other Knative Services still exist:" >&2
    printf '%s\n' "$other_services" >&2
    die "Refusing shared Serverless removal. Set FORCE_PLATFORM_CLEANUP=1 only on a disposable cluster."
  fi

  echo "==> Removing Knative Serving and OpenShift Serverless Operator resources"
  oc delete knativeserving knative-serving -n knative-serving --ignore-not-found || true
  oc delete namespace knative-serving --ignore-not-found || true
  oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found || true
  oc delete operatorgroup serverless-operators -n openshift-serverless --ignore-not-found || true
  oc delete namespace openshift-serverless --ignore-not-found || true
fi
