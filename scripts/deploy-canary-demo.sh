#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
ANALYSIS_TEMPLATE="${ANALYSIS_TEMPLATE:-rollouts-canary-demo-prometheus}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null || die "oc not found"
command -v git >/dev/null || die "git not found"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

for crd in   applications.argoproj.io   argocds.argoproj.io   rollouts.argoproj.io   rolloutmanagers.argoproj.io   analysistemplates.argoproj.io   analysisruns.argoproj.io   servicemonitors.monitoring.coreos.com
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done

oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! oc get statefulset prometheus-user-workload   -n openshift-user-workload-monitoring >/dev/null 2>&1; then
  die "OpenShift user-workload monitoring is not enabled. The canary Prometheus analysis requires prometheus-user-workload."
fi

oc get service thanos-querier   -n openshift-monitoring >/dev/null 2>&1 ||   die "OpenShift Thanos Querier service was not found."

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"
desired_revision="$(git rev-parse HEAD)"

echo "==> Applying Argo Rollouts bootstrap and enabling the Argo CD Rollouts UI"
oc apply -k bootstrap

echo "==> Applying canary Prometheus access bootstrap"
oc apply -f bootstrap/canary-prometheus-access.yaml

echo "==> Waiting for the Prometheus service-account token"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  token_data="$(oc get secret rollouts-canary-prometheus-token     -n "$NAMESPACE"     -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "$token_data" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for rollouts-canary-prometheus-token"

echo "==> Applying Argo CD Application"
oc apply -f argocd/application-canary.yaml

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME"   -n "$ARGOCD_NAMESPACE"   argocd.argoproj.io/refresh=hard   --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  revision="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  printf '    sync=%s health=%s revision=%s\n'     "${sync:-unknown}" "${health:-unknown}" "${revision:0:12}"
  [[ "$sync" == "Synced" && "$revision" == "$desired_revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD revision ${desired_revision}"

echo "==> Waiting for Prometheus AnalysisTemplate"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if oc get analysistemplate "$ANALYSIS_TEMPLATE"     -n "$NAMESPACE" >/dev/null 2>&1; then
    break
  fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for AnalysisTemplate $ANALYSIS_TEMPLATE"

echo "==> Waiting for Blackbox Exporter"
oc rollout status deployment/rollouts-canary-blackbox   -n "$NAMESPACE"   --timeout="${TIMEOUT_SECONDS}s"

echo "==> Waiting for rollout pods"
oc wait --for=condition=Ready pod   -l app="$APP_NAME"   -n "$NAMESPACE"   --timeout="${TIMEOUT_SECONDS}s"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
host="$(oc get route "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
echo
echo "Canary demo deployed: https://${host}"
echo "Prometheus gate: exact probe_http_status_code == 200, 3 consecutive samples."
echo "Next: bash scripts/start-canary-yellow.sh"
