#!/usr/bin/env bash
set -Eeuo pipefail

ROLLOUTS_NAMESPACE="${ROLLOUTS_NAMESPACE:-openshift-gitops}"
ROLLOUT_MANAGER="${ROLLOUT_MANAGER:-argo-rollout}"
ROLLOUTS_DEPLOYMENT="${ROLLOUTS_DEPLOYMENT:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
METRIC_AI_PLUGIN_VERSION="${METRIC_AI_PLUGIN_VERSION:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc rg sed sort awk; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

oc get rolloutmanager "$ROLLOUT_MANAGER" \
  -n "$ROLLOUTS_NAMESPACE" >/dev/null 2>&1 || \
  die "RolloutManager ${ROLLOUTS_NAMESPACE}/${ROLLOUT_MANAGER} not found"

if [[ -z "$ROLLOUTS_DEPLOYMENT" ]]; then
  if oc get deployment argo-rollouts \
    -n "$ROLLOUTS_NAMESPACE" >/dev/null 2>&1; then
    ROLLOUTS_DEPLOYMENT="argo-rollouts"
  else
    ROLLOUTS_DEPLOYMENT="$(
      oc get deployment \
        -n "$ROLLOUTS_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' |
      rg 'argo-rollouts' |
      sed -n '1p'
    )"
  fi
fi
[[ -n "$ROLLOUTS_DEPLOYMENT" ]] || die "Could not discover the Argo Rollouts controller Deployment"

controller_rs="$(
  oc get rs \
    -n "$ROLLOUTS_NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"\n"}{end}' |
  awk -F'|' -v deployment="$ROLLOUTS_DEPLOYMENT" \
    '$2 == "Deployment" && $3 == deployment { print $1 }'
)"
[[ -n "$controller_rs" ]] || die "Could not discover ReplicaSets owned by ${ROLLOUTS_DEPLOYMENT}"

controller_nodes="$(
  while IFS= read -r rs; do
    [[ -n "$rs" ]] || continue
    oc get pods \
      -n "$ROLLOUTS_NAMESPACE" \
      -o jsonpath='{range .items[*]}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"|"}{.spec.nodeName}{"|"}{.status.phase}{"\n"}{end}' |
    awk -F'|' -v rs="$rs" \
      '$1 == "ReplicaSet" && $2 == rs && $3 != "" && $4 == "Running" { print $3 }'
  done <<< "$controller_rs" |
  sort -u
)"
[[ -n "$controller_nodes" ]] || die "Could not determine nodes running the Argo Rollouts controller"

controller_architectures="$(
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    oc get node "$node" -o jsonpath='{.status.nodeInfo.architecture}{"\n"}'
  done <<< "$controller_nodes" |
  sort -u
)"

if [[ "$controller_architectures" != "amd64" ]]; then
  printf 'Argo Rollouts controller architecture(s):\n%s\n' "$controller_architectures" >&2
  die "metric-ai is linux-amd64; every running Rollouts-controller pod must be on amd64"
fi

echo "==> Rollouts controller runtime architecture: ${controller_architectures}"

controller_version_label="$(
  oc get deployment "$ROLLOUTS_DEPLOYMENT" \
    -n "$ROLLOUTS_NAMESPACE" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' \
    2>/dev/null || true
)"
controller_image="$(
  oc get deployment "$ROLLOUTS_DEPLOYMENT" \
    -n "$ROLLOUTS_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' \
    2>/dev/null || true
)"

label_semver=""
image_semver=""
if [[ "$controller_version_label" =~ ^v?(1\.(8|9)\.[0-9]+)([-+].*)?$ ]]; then
  label_semver="${BASH_REMATCH[1]}"
fi
if [[ "$controller_image" =~ :v?(1\.(8|9)\.[0-9]+)([-+][^@]*)?(@.*)?$ ]]; then
  image_semver="${BASH_REMATCH[1]}"
fi

if [[ -n "$label_semver" && -n "$image_semver" && "$label_semver" != "$image_semver" ]]; then
  die "Controller version label (${label_semver}) disagrees with image tag (${image_semver})"
fi

controller_semver="${label_semver:-$image_semver}"

# Red Hat controller images are normally digest-pinned, so their image
# reference often carries no upstream Argo Rollouts semver. If controller
# metadata is opaque, derive compatibility automatically from the installed
# Red Hat OpenShift GitOps CSV.
gitops_version=""
gitops_csv_namespace=""
gitops_csv_name=""
gitops_detection_source=""

gitops_subscription_record="$(
  oc get subscriptions.operators.coreos.com -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.status.installedCSV}{"\n"}{end}' \
    2>/dev/null |
  awk -F'|' '
    index(tolower($2 " " $3), "gitops") && $3 != "" {
      print $1 "|" $2 "|" $3
    }
  ' |
  sort -u |
  sed -n '1p'
)"

if [[ -n "$gitops_subscription_record" ]]; then
  IFS='|' read -r gitops_subscription_namespace gitops_subscription_name gitops_csv_name \
    <<< "$gitops_subscription_record"
  gitops_csv_namespace="$gitops_subscription_namespace"
  gitops_version="$(
    oc get csv "$gitops_csv_name" \
      -n "$gitops_csv_namespace" \
      -o jsonpath='{.spec.version}' \
      2>/dev/null || true
  )"
  if [[ -n "$gitops_version" ]]; then
    gitops_detection_source="Subscription ${gitops_subscription_namespace}/${gitops_subscription_name}"
  fi
fi

if [[ -z "$gitops_version" ]]; then
  gitops_csv_record="$(
    oc get csv -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.version}{"|"}{.spec.displayName}{"|"}{.status.phase}{"\n"}{end}' \
      2>/dev/null |
    awk -F'|' '
      index(tolower($2 " " $4), "gitops") &&
      $3 != "" &&
      $5 == "Succeeded" {
        print $1 "|" $2 "|" $3
      }
    ' |
    sort -t'|' -k3,3V |
    sed -n '$p'
  )"

  if [[ -n "$gitops_csv_record" ]]; then
    IFS='|' read -r gitops_csv_namespace gitops_csv_name gitops_version \
      <<< "$gitops_csv_record"
    gitops_detection_source="ClusterServiceVersion ${gitops_csv_namespace}/${gitops_csv_name}"
  fi
fi

gitops_rollouts_semver=""
case "$gitops_version" in
  1.21.*)
    gitops_rollouts_semver="1.9.0"
    ;;
  1.20.*)
    gitops_rollouts_semver="1.8.4"
    ;;
  1.19.*|1.18.*|1.17.*)
    gitops_rollouts_semver="1.8.3"
    ;;
esac

if [[ -n "$gitops_version" ]]; then
  echo "==> Detected Red Hat OpenShift GitOps ${gitops_version}"
  echo "    Source: ${gitops_detection_source}"
  if [[ -n "$gitops_rollouts_semver" ]]; then
    echo "    Bundled Argo Rollouts: ${gitops_rollouts_semver}"
  else
    echo "    No built-in Rollouts compatibility mapping for this GitOps release"
  fi
fi

if [[ -n "$controller_semver" && -n "$gitops_rollouts_semver" ]]; then
  controller_series="${controller_semver%.*}"
  gitops_series="${gitops_rollouts_semver%.*}"
  [[ "$controller_series" == "$gitops_series" ]] || \
    die "Controller semver ${controller_semver} disagrees with Red Hat GitOps ${gitops_version} bundle (${gitops_rollouts_semver})"
fi

effective_rollouts_semver="${controller_semver:-$gitops_rollouts_semver}"
compatibility_source=""
if [[ -n "$controller_semver" ]]; then
  compatibility_source="live controller metadata"
elif [[ -n "$gitops_rollouts_semver" ]]; then
  compatibility_source="Red Hat OpenShift GitOps ${gitops_version} component mapping"
fi

recommended_plugin=""
case "$effective_rollouts_semver" in
  1.8.*)
    recommended_plugin="v0.0.1"
    ;;
  1.9.*)
    recommended_plugin="v1.9.0"
    ;;
  "")
    ;;
  *)
    die "Unsupported detected Argo Rollouts version ${effective_rollouts_semver}"
    ;;
esac

if [[ -z "$METRIC_AI_PLUGIN_VERSION" ]]; then
  [[ -n "$recommended_plugin" ]] || {
    echo "Controller image: ${controller_image:-unknown}" >&2
    echo "Controller app.kubernetes.io/version: ${controller_version_label:-unknown}" >&2
    echo "Detected Red Hat OpenShift GitOps version: ${gitops_version:-unknown}" >&2
    die "Could not determine metric-ai compatibility automatically"
  }
  METRIC_AI_PLUGIN_VERSION="$recommended_plugin"
  echo "==> Automatically selected metric-ai ${METRIC_AI_PLUGIN_VERSION}"
  echo "    Compatibility source: ${compatibility_source}"
elif [[ -n "$recommended_plugin" && "$METRIC_AI_PLUGIN_VERSION" != "$recommended_plugin" ]]; then
  echo "WARNING: explicit METRIC_AI_PLUGIN_VERSION=${METRIC_AI_PLUGIN_VERSION}" >&2
  echo "         differs from detected recommendation ${recommended_plugin}" >&2
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

oc rollout status deployment/"$ROLLOUTS_DEPLOYMENT" \
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
echo "Rollouts controller image: ${controller_image:-unknown}"
[[ -n "$controller_semver" ]] && echo "Detected controller version: ${controller_semver}"
[[ -n "$gitops_version" ]] && echo "Detected Red Hat OpenShift GitOps: ${gitops_version}"
[[ -n "$gitops_rollouts_semver" ]] && echo "Red Hat bundled Argo Rollouts: ${gitops_rollouts_semver}"
[[ -n "$compatibility_source" ]] && echo "Compatibility source: ${compatibility_source}"
echo
echo "Compatibility never depends on the workstation Argo Rollouts CLI version."
echo "METRIC_AI_PLUGIN_VERSION remains available only as an explicit override."
