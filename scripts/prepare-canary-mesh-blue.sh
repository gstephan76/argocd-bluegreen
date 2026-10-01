#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-mesh-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-mesh-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-mesh-demo/rollout.yaml"

BLUE_IMAGE="argoproj/rollouts-demo:blue"
BLUE_MARKER="mesh-baseline-blue"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed awk; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-canary-mesh.sh
source "${SCRIPT_DIR}/lib-canary-mesh.sh"
mesh_install_wrappers

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"
mesh_enable_failure_diagnostics
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

echo "==> Verifying OpenShift Service Mesh 3.4+ prerequisite"
bash scripts/check-canary-mesh-prereqs.sh

required_mesh_assets=(
  argocd/application-canary-mesh.yaml
  bootstrap/canary-mesh-prometheus-access.yaml
  canary-mesh-demo/kustomization.yaml
  canary-mesh-demo/ingress-gateway.yaml
  canary-mesh-demo/gateway.yaml
  canary-mesh-demo/virtualservice.yaml
  canary-mesh-demo/route.yaml
  canary-mesh-demo/service-stable.yaml
  canary-mesh-demo/service-canary.yaml
  canary-mesh-demo/analysis-template.yaml
  canary-mesh-demo/podmonitor-istio-proxies.yaml
  canary-mesh-demo/rollout.yaml
  scripts/lib-canary-mesh.sh
  scripts/check-canary-mesh-prereqs.sh
  scripts/check-canary-mesh-dataplane.sh
  scripts/deploy-canary-mesh-demo.sh
)
for asset in "${required_mesh_assets[@]}"; do
  git ls-files --error-unmatch "$asset" >/dev/null 2>&1 ||     die "Required mesh demo asset is not tracked in Git: $asset"
done

mesh_status="$(
  git status --porcelain --untracked-files=all -- \
    argocd/application-canary-mesh.yaml \
    bootstrap/canary-mesh-prometheus-access.yaml \
    canary-mesh-demo \
    scripts/lib-canary-mesh.sh \
    scripts/check-canary-mesh-prereqs.sh \
    scripts/check-canary-mesh-dataplane.sh \
    scripts/deploy-canary-mesh-demo.sh \
    scripts/prepare-canary-mesh-blue.sh \
    scripts/start-canary-mesh-yellow.sh \
    scripts/promote-canary-mesh-stable.sh \
    scripts/sample-canary-mesh-traffic.sh
)"
if [[ -n "$mesh_status" ]]; then
  printf '%s\n' "$mesh_status" >&2
  die "Mesh demo files must be committed before prepare mutates rollout.yaml"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi
branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

echo "==> Restoring canonical BLUE mesh-canary baseline in Git"
sed -i -E 's#image: argoproj/rollouts-demo:(blue|yellow)#image: argoproj/rollouts-demo:blue#' "$ROLLOUT_FILE"
sed -i -E "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"${BLUE_MARKER}\"#" "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already declares the canonical BLUE mesh baseline"
else
  git commit -m "Restore mesh canary blue baseline"
  git push origin "$branch"
fi
revision="$(git rev-parse HEAD)"

if ! oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  bash scripts/deploy-canary-mesh-demo.sh
else
  oc annotate applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
fi

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
if ! mesh_wait_argocd_revision "$APP_NAME" "$ARGOCD_NAMESPACE" "$revision" "$TIMEOUT_SECONDS" "$POLL_SECONDS"; then
  die "Argo CD did not reconcile exact revision ${revision}"
fi

echo "==> Recovering trusted canonical BLUE mesh baseline"
full_promotion_requested=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  current_image=""
  [[ -z "$current" ]] || current_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${current}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  weights="$(oc get virtualservice rollouts-mesh-canary -n "$NAMESPACE" -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%' 2>/dev/null || true)"
  printf '    phase=%s stable=%s current=%s image=%s weights="%s"\n' "${phase:-unknown}" "${stable:-none}" "${current:-none}" "${live_image:-unknown}" "${weights:-unknown}"

  if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" && "$live_image" == "$BLUE_IMAGE" && "$live_marker" == "$BLUE_MARKER" && "$current_image" == "$BLUE_IMAGE" ]]; then
    break
  fi

  if [[ "$live_image" == "$BLUE_IMAGE" && "$live_marker" == "$BLUE_MARKER" && -n "$current" && "$stable" != "$current" && "$phase" != "Healthy" && "$current_image" == "$BLUE_IMAGE" && "$full_promotion_requested" == "0" ]]; then
    echo "==> Fully promoting verified canonical BLUE recovery"
    oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE" --full >/dev/null
    full_promotion_requested=1
  fi
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring canonical BLUE mesh baseline"

echo "==> Revalidating platform, mesh, and GitOps dependencies"
bash scripts/deploy-canary-mesh-demo.sh

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Canonical BLUE mesh-canary baseline is Healthy and stable."
