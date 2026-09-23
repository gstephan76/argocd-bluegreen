#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUTS_DEPLOYMENT="${ROLLOUTS_DEPLOYMENT:-}"
TARGET_REVISION="${TARGET_REVISION:-main}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"

EXPECTED_REPO_HTTP="https://github.com/gstephan76/argocd-bluegreen.git"
EXPECTED_REPO_SSH="git@github.com:gstephan76/argocd-bluegreen.git"

ANALYSIS_BASE_URL="${ANALYSIS_BASE_URL:-https://api.openai.com/v1}"
ANALYSIS_MODEL="${ANALYSIS_MODEL:-gpt-4o}"

REMEDIATE=0

usage() {
  cat <<'EOF'
Usage:
  scripts/preflight-metric-ai-demo.sh
  scripts/preflight-metric-ai-demo.sh --remediate

Without --remediate:
  validate the complete Metric-AI demo dependency chain without changing it.

With --remediate:
  automatically repair only safe/idempotent infrastructure drift:
    - metric-ai RolloutManager plugin configuration
    - metric-ai-demo namespace
    - AI-agent Secret when ANALYSIS_API_KEY is supplied
    - AI-agent Deployment/Service/RBAC
    - Argo CD Application and hard refresh
    - Argo Rollouts controller pod-log RoleBinding

The script never:
  - commits or pushes Git changes
  - changes the demo image or rollout revision annotation
  - promotes, aborts, or resets a Rollout
  - overwrites another metric provider plugin
EOF
}

while (($#)); do
  case "$1" in
    --remediate)
      REMEDIATE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

die() {
  echo
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  printf '[PASS] %s\n' "$*"
}

fix() {
  printf '[FIX ] %s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_for() {
  local description="$1"
  shift
  local deadline=$((SECONDS + TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if "$@"; then
      return 0
    else
      rc=$?
      if (( rc == 2 )); then
        return 2
      fi
    fi
    sleep "$POLL_SECONDS"
  done

  die "Timed out waiting for: ${description}"
}

secret_field_present() {
  local key="$1"
  local value
  value="$(
    oc get secret "$AGENT_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o "jsonpath={.data.${key}}" 2>/dev/null || true
  )"
  [[ -n "$value" ]]
}

app_synced_to_head() {
  local sync revision
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
  info "Argo CD sync=${sync:-unknown} revision=${revision:0:12}"
  [[ "$sync" == "Synced" && "$revision" == "$HEAD_REVISION" ]]
}

rollout_exists() {
  oc get rollout "$APP_NAME" -n "$NAMESPACE" >/dev/null 2>&1
}

rollout_healthy() {
  local phase stable current
  phase="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  stable="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.stableRS}' 2>/dev/null || true
  )"
  current="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true
  )"

  info "Rollout phase=${phase:-unknown} stable=${stable:-none} current=${current:-none}"

  if [[ "$phase" == "Degraded" ]]; then
    echo
    echo "The demo is in a failed/degraded state." >&2
    echo "Inspect it with:" >&2
    echo "  bash scripts/show-metric-ai-analysis.sh" >&2
    echo "Then restore the known-good GitOps baseline with:" >&2
    echo "  bash scripts/reset-metric-ai-demo.sh" >&2
    return 2
  fi

  if [[ "$phase" == "Paused" ]]; then
    echo
    echo "The demo is paused in an existing rollout." >&2
    echo "Finish that workflow before starting another scenario." >&2
    echo "For an AI-approved candidate:" >&2
    echo "  bash scripts/promote-metric-ai-stable.sh" >&2
    echo "For an unwanted/failed scenario:" >&2
    echo "  bash scripts/reset-metric-ai-demo.sh" >&2
    return 2
  fi

  [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]]
}

cleanup_health_pod() {
  if [[ -n "${HEALTH_POD:-}" ]]; then
    oc delete pod "$HEALTH_POD" \
      -n "$ARGOCD_NAMESPACE" \
      --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup_health_pod EXIT

echo "============================================================"
echo " Metric-AI demo pre-flight"
if (( REMEDIATE )); then
  echo " mode: validate + safe remediation"
else
  echo " mode: validate only"
fi
echo "============================================================"

for c in oc git rg sed awk sort; do
  require_command "$c"
done
pass "Required local commands are available"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
pass "Repository root: $ROOT"

required_files=(
  argocd/application-metric-ai.yaml
  metric-ai-demo/app/analysis-template.yaml
  metric-ai-demo/app/rollout.yaml
  metric-ai-demo/app/rbac.yaml
  metric-ai-demo/agent/kustomization.yaml
  scripts/install-metric-ai-plugin.sh
)

for f in "${required_files[@]}"; do
  [[ -f "$f" ]] || die "Required repository file missing: $f"
done
pass "Metric-AI repository assets are present"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist. Commit or restore them before pre-flight."
fi
pass "Tracked Git tree is clean"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
[[ "$branch" == "$TARGET_REVISION" ]] || \
  die "Current branch is '$branch' but Argo CD targetRevision is '$TARGET_REVISION'"
pass "Current branch matches Argo CD targetRevision: $TARGET_REVISION"

origin_url="$(git remote get-url origin 2>/dev/null || true)"
case "$origin_url" in
  "$EXPECTED_REPO_HTTP"|https://github.com/gstephan76/argocd-bluegreen|"$EXPECTED_REPO_SSH")
    ;;
  *)
    die "origin points to '$origin_url'; expected the argocd-bluegreen repository used by the Argo CD Application"
    ;;
esac
pass "Git origin matches the Argo CD repository"

info "Fetching origin/${TARGET_REVISION}"
git fetch origin "$TARGET_REVISION"

read -r behind ahead < <(
  git rev-list --left-right --count "origin/${TARGET_REVISION}...HEAD"
)
(( behind == 0 && ahead == 0 )) || \
  die "Local ${TARGET_REVISION} must exactly match origin/${TARGET_REVISION} (behind=${behind}, ahead=${ahead})"

HEAD_REVISION="$(git rev-parse HEAD)"
pass "Git HEAD matches origin/${TARGET_REVISION}: ${HEAD_REVISION:0:12}"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
pass "OpenShift login is valid"

cluster_version="$(
  oc get clusterversion version \
    -o jsonpath='{.status.desired.version}' 2>/dev/null || true
)"
[[ -n "$cluster_version" ]] || die "Could not determine OpenShift cluster version"

major="${cluster_version%%.*}"
minor_rest="${cluster_version#*.}"
minor="${minor_rest%%.*}"

[[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || \
  die "Could not parse OpenShift version: $cluster_version"

if (( major < 4 || (major == 4 && minor < 20) )); then
  die "OpenShift ${cluster_version} is older than the demo requirement (4.20+)"
fi
pass "OpenShift version ${cluster_version}"

required_crds=(
  applications.argoproj.io
  rolloutmanagers.argoproj.io
  rollouts.argoproj.io
  analysistemplates.argoproj.io
  analysisruns.argoproj.io
)

for crd in "${required_crds[@]}"; do
  oc get crd "$crd" >/dev/null 2>&1 || die "Missing required CRD: $crd"
done
pass "Required Argo CD / Argo Rollouts CRDs are installed"

oc argo rollouts version >/dev/null 2>&1 || \
  die "The 'oc argo rollouts' CLI plugin is required"
pass "Argo Rollouts CLI plugin is available"

architectures="$(
  oc get nodes \
    -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' |
  sort -u
)"
[[ "$architectures" == "amd64" ]] || {
  printf 'Detected node architecture(s):\n%s\n' "$architectures" >&2
  die "The published metric-ai binary used by this demo is linux-amd64"
}
pass "Cluster node architecture is amd64"

oc get rolloutmanager "$ROLLOUT_MANAGER" \
  -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || \
  die "RolloutManager ${ARGOCD_NAMESPACE}/${ROLLOUT_MANAGER} does not exist"

other_metric_plugins="$(
  oc get rolloutmanager "$ROLLOUT_MANAGER" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{range .spec.plugins.metric[*]}{.name}{"\n"}{end}' \
    2>/dev/null |
  sed '/^$/d' |
  rg -v '^argoproj-labs/metric-ai$' || true
)"

[[ -z "$other_metric_plugins" ]] || {
  echo "Existing metric provider plugins:" >&2
  printf '%s\n' "$other_metric_plugins" >&2
  die "Refusing automatic remediation because another metric provider is configured"
}

metric_plugin_in_rm="$(
  oc get rolloutmanager "$ROLLOUT_MANAGER" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{range .spec.plugins.metric[*]}{.name}{"\n"}{end}' \
    2>/dev/null |
  rg '^argoproj-labs/metric-ai$' || true
)"

metric_plugin_in_cm="$(
  oc get configmap argo-rollouts-config \
    -n "$ARGOCD_NAMESPACE" \
    -o yaml 2>/dev/null |
  rg 'argoproj-labs/metric-ai' || true
)"

rolloutmanager_phase="$(
  oc get rolloutmanager "$ROLLOUT_MANAGER" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
)"

if [[ -z "$metric_plugin_in_rm" ||
      -z "$metric_plugin_in_cm" ||
      "$rolloutmanager_phase" != "Available" ]]; then
  if (( REMEDIATE )); then
    fix "Reconciling metric-ai plugin through RolloutManager"
    bash scripts/install-metric-ai-plugin.sh
  else
    die "metric-ai plugin is not fully reconciled; rerun with --remediate"
  fi
fi

rolloutmanager_phase="$(
  oc get rolloutmanager "$ROLLOUT_MANAGER" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
)"
[[ "$rolloutmanager_phase" == "Available" ]] || \
  die "RolloutManager phase is '${rolloutmanager_phase:-unknown}', expected Available"

oc get configmap argo-rollouts-config \
  -n "$ARGOCD_NAMESPACE" \
  -o yaml |
rg -q 'argoproj-labs/metric-ai' || \
  die "argo-rollouts-config does not contain argoproj-labs/metric-ai"
pass "metric-ai provider is reconciled into Argo Rollouts"

if [[ -z "$ROLLOUTS_DEPLOYMENT" ]]; then
  if oc get deployment argo-rollouts \
    -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    ROLLOUTS_DEPLOYMENT="argo-rollouts"
  else
    ROLLOUTS_DEPLOYMENT="$(
      oc get deployment \
        -n "$ARGOCD_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
      rg 'argo-rollouts' |
      sed -n '1p'
    )"
  fi
fi

[[ -n "$ROLLOUTS_DEPLOYMENT" ]] || \
  die "Could not discover the Argo Rollouts controller Deployment"

oc rollout status deployment/"$ROLLOUTS_DEPLOYMENT" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s" >/dev/null
pass "Argo Rollouts controller Deployment is ready: $ROLLOUTS_DEPLOYMENT"

ROLLOUTS_SA="$(
  oc get deployment "$ROLLOUTS_DEPLOYMENT" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true
)"
[[ -n "$ROLLOUTS_SA" ]] || \
  die "Could not determine the Argo Rollouts controller ServiceAccount"
pass "Argo Rollouts controller ServiceAccount: $ROLLOUTS_SA"

if ! oc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  if (( REMEDIATE )); then
    fix "Creating namespace ${NAMESPACE}"
    oc create namespace "$NAMESPACE" >/dev/null
  else
    die "Namespace ${NAMESPACE} is missing; rerun with --remediate"
  fi
fi
pass "Namespace ${NAMESPACE} exists"

secret_ok=1
for key in analysis_api_key analysis_base_url analysis_model; do
  secret_field_present "$key" || secret_ok=0
done

if (( ! secret_ok )); then
  if (( ! REMEDIATE )); then
    die "AI-agent Secret is missing/incomplete; rerun with --remediate and ANALYSIS_API_KEY"
  fi

  [[ -n "${ANALYSIS_API_KEY:-}" ]] || {
    cat >&2 <<EOF

[FAIL] AI-agent Secret is missing/incomplete and ANALYSIS_API_KEY is not set.

Set model credentials, for example:

  export ANALYSIS_API_KEY='...'
  export ANALYSIS_BASE_URL='https://api.openai.com/v1'
  export ANALYSIS_MODEL='gpt-4o'

Or for LiteLLM/vLLM:

  export ANALYSIS_API_KEY='dummy'
  export ANALYSIS_BASE_URL='http://<service>:<port>/v1'
  export ANALYSIS_MODEL='<model-name>'

Then rerun:
  bash scripts/preflight-metric-ai-demo.sh --remediate
EOF
    exit 1
  }

  fix "Creating/updating ${ARGOCD_NAMESPACE}/${AGENT_NAME} Secret"

  secret_args=(
    create secret generic "$AGENT_NAME"
    -n "$ARGOCD_NAMESPACE"
    "--from-literal=analysis_api_key=${ANALYSIS_API_KEY}"
    "--from-literal=analysis_base_url=${ANALYSIS_BASE_URL}"
    "--from-literal=analysis_model=${ANALYSIS_MODEL}"
  )

  [[ -n "${REMEDIATION_API_KEY:-}" ]] && \
    secret_args+=("--from-literal=remediation_api_key=${REMEDIATION_API_KEY}")
  [[ -n "${REMEDIATION_BASE_URL:-}" ]] && \
    secret_args+=("--from-literal=remediation_base_url=${REMEDIATION_BASE_URL}")
  [[ -n "${REMEDIATION_MODEL:-}" ]] && \
    secret_args+=("--from-literal=remediation_model=${REMEDIATION_MODEL}")
  [[ -n "${GITHUB_TOKEN:-}" ]] && \
    secret_args+=("--from-literal=github_token=${GITHUB_TOKEN}")

  oc "${secret_args[@]}" \
    --dry-run=client \
    -o yaml |
  oc apply -f - >/dev/null
fi
pass "AI-agent Secret has analysis API key/base URL/model fields"

if (( REMEDIATE )); then
  fix "Reconciling AI-agent Deployment, Service, ServiceAccount, and diagnostic RBAC"
  oc apply -k metric-ai-demo/agent >/dev/null
else
  for resource in \
    "serviceaccount/${AGENT_NAME}" \
    "deployment/${AGENT_NAME}" \
    "service/${AGENT_NAME}"
  do
    oc get "$resource" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || \
      die "Missing ${ARGOCD_NAMESPACE}/${resource}; rerun with --remediate"
  done

  oc get role metric-ai-kubernetes-agent-reader \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    die "Missing agent diagnostic Role; rerun with --remediate"

  oc get rolebinding metric-ai-kubernetes-agent-reader \
    -n "$NAMESPACE" >/dev/null 2>&1 || \
    die "Missing agent diagnostic RoleBinding; rerun with --remediate"
fi

oc rollout status deployment/"$AGENT_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s" >/dev/null || {
    echo
    oc get pod -n "$ARGOCD_NAMESPACE" -l app="$AGENT_NAME" -o wide || true
    oc describe deployment "$AGENT_NAME" -n "$ARGOCD_NAMESPACE" || true
    die "AI-agent Deployment did not become ready"
  }
pass "AI-agent Deployment is ready"

agent_endpoint="$(
  oc get endpoints "$AGENT_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
)"
[[ -n "$agent_endpoint" ]] || \
  die "AI-agent Service has no ready endpoint"
pass "AI-agent Service has a ready endpoint"

desired_repo="$(
  awk '
    $1 == "repoURL:" { print $2; exit }
  ' argocd/application-metric-ai.yaml
)"
desired_path="$(
  awk '
    $1 == "path:" { print $2; exit }
  ' argocd/application-metric-ai.yaml
)"
desired_target="$(
  awk '
    $1 == "targetRevision:" { print $2; exit }
  ' argocd/application-metric-ai.yaml
)"

[[ "$desired_repo" == "$EXPECTED_REPO_HTTP" ]] || \
  die "Argo CD manifest repoURL is unexpected: $desired_repo"
[[ "$desired_path" == "metric-ai-demo/app" ]] || \
  die "Argo CD manifest path is unexpected: $desired_path"
[[ "$desired_target" == "$TARGET_REVISION" ]] || \
  die "Argo CD manifest targetRevision '$desired_target' does not match '$TARGET_REVISION'"

desired_image="$(
  awk '
    /^[[:space:]]*image:[[:space:]]+ghcr.io\/kdubois\/argo-rollouts-quarkus-demo:/ {
      print $2
      exit
    }
  ' metric-ai-demo/app/rollout.yaml
)"

if ! rollout_exists &&
   [[ "$desired_image" != "ghcr.io/kdubois/argo-rollouts-quarkus-demo:v1.stable" ]]; then
  die "Refusing first bootstrap because Git desired image is not v1.stable: ${desired_image:-unknown}"
fi

app_exists=1
oc get applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || app_exists=0

app_matches=0
if (( app_exists )); then
  live_repo="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || true
  )"
  live_path="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.spec.source.path}' 2>/dev/null || true
  )"
  live_target="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || true
  )"
  live_destination="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true
  )"

  if [[ "$live_repo" == "$desired_repo" &&
        "$live_path" == "$desired_path" &&
        "$live_target" == "$desired_target" &&
        "$live_destination" == "$NAMESPACE" ]]; then
    app_matches=1
  fi
fi

if (( ! app_exists || ! app_matches )); then
  if (( REMEDIATE )); then
    if (( ! app_exists )); then
      fix "Creating missing Argo CD Application ${ARGOCD_NAMESPACE}/${APP_NAME}"
    else
      fix "Reconciling drifted Argo CD Application ${ARGOCD_NAMESPACE}/${APP_NAME}"
    fi
    oc apply -f argocd/application-metric-ai.yaml >/dev/null
  else
    die "Argo CD Application is missing or drifted; rerun with --remediate"
  fi
fi
pass "Argo CD Application exists with expected repo/path/target/destination"

if (( REMEDIATE )); then
  fix "Requesting Argo CD hard refresh"
  oc annotate applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    argocd.argoproj.io/refresh=hard \
    --overwrite >/dev/null
fi

wait_for "Argo CD to sync ${HEAD_REVISION:0:12}" app_synced_to_head
pass "Argo CD is Synced to Git HEAD ${HEAD_REVISION:0:12}"

for resource in \
  "analysistemplate/metric-ai-analysis" \
  "role/metric-ai-rollouts-plugin-reader" \
  "route/metric-ai-demo"
do
  oc get "$resource" -n "$NAMESPACE" >/dev/null 2>&1 || \
    die "Expected GitOps resource missing after sync: ${NAMESPACE}/${resource}"
done

wait_for "Rollout ${NAMESPACE}/${APP_NAME} to exist" rollout_exists

if ! wait_for "Rollout ${NAMESPACE}/${APP_NAME} to become healthy" rollout_healthy; then
  die "Rollout did not reach the required known-good baseline"
fi
pass "Rollout is Healthy with stableRS == currentPodHash"

if (( REMEDIATE )); then
  fix "Reconciling Rollouts-controller pod-log RoleBinding"
  oc create rolebinding metric-ai-rollouts-plugin-reader \
    -n "$NAMESPACE" \
    --role=metric-ai-rollouts-plugin-reader \
    "--serviceaccount=${ARGOCD_NAMESPACE}:${ROLLOUTS_SA}" \
    --dry-run=client \
    -o yaml |
  oc apply -f - >/dev/null
fi

controller_identity="system:serviceaccount:${ARGOCD_NAMESPACE}:${ROLLOUTS_SA}"
agent_identity="system:serviceaccount:${ARGOCD_NAMESPACE}:${AGENT_NAME}"

oc auth can-i list pods \
  -n "$NAMESPACE" \
  --as="$controller_identity" |
rg -qx 'yes' || \
  die "Rollouts controller cannot list candidate/stable pods in ${NAMESPACE}"

oc auth can-i get pods/log \
  -n "$NAMESPACE" \
  --as="$controller_identity" |
rg -qx 'yes' || \
  die "Rollouts controller cannot read pod logs in ${NAMESPACE}"

oc auth can-i list pods \
  -n "$NAMESPACE" \
  --as="$agent_identity" |
rg -qx 'yes' || \
  die "AI agent cannot list pods in ${NAMESPACE}"

oc auth can-i get pods/log \
  -n "$NAMESPACE" \
  --as="$agent_identity" |
rg -qx 'yes' || \
  die "AI agent cannot read pod logs in ${NAMESPACE}"

oc auth can-i list events \
  -n "$NAMESPACE" \
  --as="$agent_identity" |
rg -qx 'yes' || \
  die "AI agent cannot list events in ${NAMESPACE}"

oc auth can-i get rollouts.argoproj.io \
  -n "$NAMESPACE" \
  --as="$agent_identity" |
rg -qx 'yes' || \
  die "AI agent cannot read Argo Rollouts in ${NAMESPACE}"

pass "Metric plugin and AI-agent RBAC checks passed"

HEALTH_POD="metric-ai-preflight-health-$$"

oc run "$HEALTH_POD" \
  -n "$ARGOCD_NAMESPACE" \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  --command -- \
  sh -c "curl --fail --silent --show-error http://${AGENT_NAME}:8080/q/health" \
  >/dev/null

if ! oc wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/"$HEALTH_POD" \
  -n "$ARGOCD_NAMESPACE" \
  --timeout=90s >/dev/null 2>&1; then
  echo
  oc logs "$HEALTH_POD" -n "$ARGOCD_NAMESPACE" || true
  oc describe pod "$HEALTH_POD" -n "$ARGOCD_NAMESPACE" || true
  die "In-cluster AI-agent health request failed"
fi

health_output="$(oc logs "$HEALTH_POD" -n "$ARGOCD_NAMESPACE" 2>/dev/null || true)"
[[ -n "$health_output" ]] || \
  die "AI-agent health request succeeded but returned no output"

pass "AI-agent /q/health is reachable from inside the cluster"

echo
echo "============================================================"
echo " Metric-AI pre-flight: READY"
echo "============================================================"
echo "Git revision:       ${HEAD_REVISION}"
echo "Argo CD app:        ${ARGOCD_NAMESPACE}/${APP_NAME}"
echo "Target namespace:   ${NAMESPACE}"
echo "RolloutManager:     ${ARGOCD_NAMESPACE}/${ROLLOUT_MANAGER}"
echo "Rollouts controller:${ARGOCD_NAMESPACE}/${ROLLOUTS_DEPLOYMENT}"
echo "AI agent:           ${ARGOCD_NAMESPACE}/${AGENT_NAME}"
echo
echo "No Git commits or rollout mutations were performed by pre-flight."
