#!/usr/bin/env bash
set -Eeuo pipefail

ROLLOUTS_NAMESPACE="${ROLLOUTS_NAMESPACE:-openshift-gitops}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
METRIC_AI_PLUGIN_VERSION="${METRIC_AI_PLUGIN_VERSION:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc rg sed sort; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

oc get rolloutmanager "$ROLLOUT_MANAGER" \
  -n "$ROLLOUTS_NAMESPACE" >/dev/null 2>&1 || \
  die "RolloutManager ${ROLLOUTS_NAMESPACE}/${ROLLOUT_MANAGER} not found"

architectures="$(
  oc get nodes \
    -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' |
  sort -u
)"

if [[ "$architectures" != "amd64" ]]; then
  printf 'Detected node architecture(s):\n%s\n' "$architectures" >&2
  die "The published metric-ai release artifact used by this demo is linux-amd64"
fi

if [[ -z "$METRIC_AI_PLUGIN_VERSION" ]]; then
  cli_version="$(oc argo rollouts version --short 2>/dev/null || true)"
  if printf '%s\n' "$cli_version" | rg -q '^v?1\.8\.'; then
    METRIC_AI_PLUGIN_VERSION="v0.0.1"
  elif printf '%s\n' "$cli_version" | rg -q '^v?1\.(9|[1-9][0-9])\.'; then
    METRIC_AI_PLUGIN_VERSION="v1.9.0"
  else
    echo "WARNING: Could not map the local Argo Rollouts CLI version to an upstream metric-ai release." >&2
    echo "         Defaulting to v1.9.0. Set METRIC_AI_PLUGIN_VERSION explicitly if your controller is 1.8.x." >&2
    METRIC_AI_PLUGIN_VERSION="v1.9.0"
  fi
fi

case "$METRIC_AI_PLUGIN_VERSION" in
  v0.0.1)
    plugin_sha256="5ce6a589f292a932965511a65631a4cf9d2604778a2df3adaec26fd9c6bc9f4b"
    ;;
  v1.9.0)
    plugin_sha256="9da7dc6f0ed0af05b14dcdb4dda3bb264b15778f7df1c944dc0ea018efe7d51d"
    ;;
  *)
    die "Unsupported METRIC_AI_PLUGIN_VERSION=${METRIC_AI_PLUGIN_VERSION}; use v0.0.1 or v1.9.0"
    ;;
esac

plugin_url="https://github.com/argoproj-labs/rollouts-plugin-metric-ai/releases/download/${METRIC_AI_PLUGIN_VERSION}/rollouts-plugin-metric-ai-linux-amd64"

existing_plugins="$(
  oc get rolloutmanager "$ROLLOUT_MANAGER" \
    -n "$ROLLOUTS_NAMESPACE" \
    -o jsonpath='{range .spec.plugins.metric[*]}{.name}{"\n"}{end}' \
    2>/dev/null || true
)"

if [[ -n "$existing_plugins" ]]; then
  while IFS= read -r plugin; do
    [[ -z "$plugin" ]] && continue
    [[ "$plugin" == "argoproj-labs/metric-ai" ]] || \
      die "RolloutManager already has metric plugin '${plugin}'. Refusing to replace another metric plugin."
  done <<< "$existing_plugins"
fi

echo "==> Configuring metric-ai ${METRIC_AI_PLUGIN_VERSION}"
echo "    RolloutManager: ${ROLLOUTS_NAMESPACE}/${ROLLOUT_MANAGER}"
echo "    URL: ${plugin_url}"

patch="$(
cat <<JSON
{
  "spec": {
    "plugins": {
      "metric": [
        {
          "name": "argoproj-labs/metric-ai",
          "location": "${plugin_url}",
          "sha256": "${plugin_sha256}"
        }
      ]
    }
  }
}
JSON
)"

oc patch rolloutmanager "$ROLLOUT_MANAGER" \
  -n "$ROLLOUTS_NAMESPACE" \
  --type=merge \
  -p "$patch"

echo "==> Waiting for RolloutManager Available"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(
    oc get rolloutmanager "$ROLLOUT_MANAGER" \
      -n "$ROLLOUTS_NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  printf '    phase=%s\n' "${phase:-unknown}"
  [[ "$phase" == "Available" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for RolloutManager"

rollouts_deployment="$(
  oc get deployment \
    -n "$ROLLOUTS_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
  rg '^argo-rollouts$' |
  sed -n '1p'
)"
[[ -n "$rollouts_deployment" ]] || die "Could not find deployment/argo-rollouts"

oc rollout status deployment/"$rollouts_deployment" \
  -n "$ROLLOUTS_NAMESPACE" \
  --timeout="${TIMEOUT_SECONDS}s"

echo "==> Verifying generated plugin configuration"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  config="$(
    oc get configmap argo-rollouts-config \
      -n "$ROLLOUTS_NAMESPACE" \
      -o yaml 2>/dev/null || true
  )"
  printf '%s\n' "$config" | rg -q 'argoproj-labs/metric-ai' && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "metric-ai was not rendered into argo-rollouts-config"

echo
echo "metric-ai plugin is configured."
echo "Selected upstream release: ${METRIC_AI_PLUGIN_VERSION}"
echo
echo "NOTE: the local CLI version is only a compatibility hint."
echo "If your Red Hat Rollouts controller is 1.8.x, use METRIC_AI_PLUGIN_VERSION=v0.0.1."
echo "For controller 1.9.x, use METRIC_AI_PLUGIN_VERSION=v1.9.0."
