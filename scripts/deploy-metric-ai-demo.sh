#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

ANALYSIS_BASE_URL="${ANALYSIS_BASE_URL:-https://api.openai.com/v1}"
ANALYSIS_MODEL="${ANALYSIS_MODEL:-gpt-4o}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git rg; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

for crd in \
  applications.argoproj.io \
  rolloutmanagers.argoproj.io \
  rollouts.argoproj.io \
  analysistemplates.argoproj.io \
  analysisruns.argoproj.io
do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing CRD: $crd"
done

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist. Commit or restore them before deploying this GitOps demo."
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"
desired_revision="$(git rev-parse HEAD)"

echo "==> Installing/reconciling metric-ai provider plugin"
bash scripts/install-metric-ai-plugin.sh

echo "==> Ensuring target namespace exists before cross-namespace agent RBAC"
oc create namespace "$NAMESPACE" \
  --dry-run=client \
  -o yaml |
oc apply -f -

if [[ -n "${ANALYSIS_API_KEY:-}" ]]; then
  echo "==> Creating/updating isolated AI-agent Secret"
  args=(
    create secret generic "$AGENT_NAME"
    -n "$ARGOCD_NAMESPACE"
    "--from-literal=analysis_api_key=${ANALYSIS_API_KEY}"
    "--from-literal=analysis_base_url=${ANALYSIS_BASE_URL}"
    "--from-literal=analysis_model=${ANALYSIS_MODEL}"
  )

  [[ -n "${REMEDIATION_API_KEY:-}" ]] && \
    args+=("--from-literal=remediation_api_key=${REMEDIATION_API_KEY}")
  [[ -n "${REMEDIATION_BASE_URL:-}" ]] && \
    args+=("--from-literal=remediation_base_url=${REMEDIATION_BASE_URL}")
  [[ -n "${REMEDIATION_MODEL:-}" ]] && \
    args+=("--from-literal=remediation_model=${REMEDIATION_MODEL}")
  [[ -n "${GITHUB_TOKEN:-}" ]] && \
    args+=("--from-literal=github_token=${GITHUB_TOKEN}")

  oc "${args[@]}" \
    --dry-run=client \
    -o yaml |
  oc apply -f -
elif oc get secret "$AGENT_NAME" \
  -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "==> Reusing existing ${ARGOCD_NAMESPACE}/${AGENT_NAME} Secret"
else
  cat >&2 <<EOF
ERROR: AI model credentials are not configured.

Example:

  export ANALYSIS_API_KEY='...'
  export ANALYSIS_BASE_URL='https://api.openai.com/v1'
  export ANALYSIS_MODEL='gpt-4o'

For an OpenAI-compatible LiteLLM/vLLM endpoint:

  export ANALYSIS_API_KEY='dummy'
  export ANALYSIS_BASE_URL='http://<service>:<port>/v1'
  export ANALYSIS_MODEL='<model-name>'

Then rerun this script.
EOF
  exit 1
fi

echo "==> Deploying Kubernetes AIOps agent"
oc apply -k metric-ai-demo/agent

oc rollout status deployment/"$AGENT_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s"

echo "==> Verifying agent health in-cluster"
health_pod="metric-ai-agent-health"
oc delete pod "$health_pod" \
  -n "$ARGOCD_NAMESPACE" \
  --ignore-not-found >/dev/null 2>&1 || true

oc run "$health_pod" \
  -n "$ARGOCD_NAMESPACE" \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  --command -- \
  sh -c "curl --fail --silent --show-error http://${AGENT_NAME}:8080/q/health"

oc wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/"$health_pod" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=90s

oc logs "$health_pod" -n "$ARGOCD_NAMESPACE"
oc delete pod "$health_pod" \
  -n "$ARGOCD_NAMESPACE" \
  --ignore-not-found >/dev/null

echo "==> Applying Argo CD Application"
oc apply -f argocd/application-metric-ai.yaml

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true
  )"
  revision="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
  )"

  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${revision:0:12}"
  [[ "$sync" == "Synced" && "$revision" == "$desired_revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for initial stable Rollout"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  printf '    rollout phase=%s\n' "${phase:-unknown}"
  [[ "$phase" == "Healthy" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for initial stable Rollout"

echo "==> Granting metric plugin pod-log read access to Rollouts controller"
rollouts_sa="$(
  oc get deployment argo-rollouts \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true
)"
[[ -n "$rollouts_sa" ]] || die "Could not determine Argo Rollouts controller ServiceAccount"

oc create rolebinding metric-ai-rollouts-plugin-reader \
  -n "$NAMESPACE" \
  --role=metric-ai-rollouts-plugin-reader \
  "--serviceaccount=${ARGOCD_NAMESPACE}:${rollouts_sa}" \
  --dry-run=client \
  -o yaml |
oc apply -f -

host="$(
  oc get route "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.spec.host}'
)"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Metric-AI demo deployed."
echo "Application: https://${host}"
echo
echo "Next:"
echo "  Healthy AI gate: bash scripts/start-metric-ai-healthy.sh"
echo "  Failure AI gate: bash scripts/start-metric-ai-failure.sh"
