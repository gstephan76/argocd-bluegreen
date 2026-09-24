#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-demo/rollout.yaml"

BLUE_IMAGE="argoproj/rollouts-demo:blue"
BLUE_MARKER="baseline-blue"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed awk; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts CLI plugin is required"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

echo "==> Restoring canonical BLUE canary baseline in Git"
sed -i -E \
  's#image: argoproj/rollouts-demo:(blue|yellow)#image: argoproj/rollouts-demo:blue#' \
  "$ROLLOUT_FILE"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"${BLUE_MARKER}\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check

if git diff --cached --quiet; then
  echo "==> Git already declares the canonical BLUE baseline"
else
  git commit -m "Restore canary blue baseline"
  git push origin "$branch"
fi

revision="$(git rev-parse HEAD)"

if ! oc get applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  echo "==> Canary Application is absent; bootstrapping the demo"
  bash scripts/deploy-canary-demo.sh
else
  oc annotate applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    argocd.argoproj.io/refresh=hard \
    --overwrite >/dev/null
fi

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true
  )"
  got="$(
    oc get applications.argoproj.io "$APP_NAME" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
  )"
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  [[ "$sync" == "Synced" && "$got" == "$revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Recovering trusted canonical BLUE baseline"
full_promotion_requested=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  live_image="$(
    oc get rollout "$APP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
  )"
  live_marker="$(
    oc get rollout "$APP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true
  )"
  phase="$(
    oc get rollout "$APP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true
  )"
  stable="$(
    oc get rollout "$APP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.stableRS}' 2>/dev/null || true
  )"
  current="$(
    oc get rollout "$APP_NAME" -n "$NAMESPACE" \
      -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true
  )"
  current_image=""
  [[ -z "$current" ]] || current_image="$(
    oc get pods -n "$NAMESPACE" \
      -l "rollouts-pod-template-hash=${current}" \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true
  )"

  printf '    phase=%s stable=%s current=%s image=%s marker=%s\n' \
    "${phase:-unknown}" "${stable:-none}" "${current:-none}" \
    "${live_image:-unknown}" "${live_marker:-unknown}"

  if [[ "$phase" == "Healthy" &&
        -n "$stable" &&
        "$stable" == "$current" &&
        "$live_image" == "$BLUE_IMAGE" &&
        "$live_marker" == "$BLUE_MARKER" &&
        "$current_image" == "$BLUE_IMAGE" ]]; then
    break
  fi

  if [[ "$live_image" == "$BLUE_IMAGE" &&
        "$live_marker" == "$BLUE_MARKER" &&
        -n "$current" &&
        "$stable" != "$current" &&
        "$phase" != "Healthy" &&
        "$current_image" == "$BLUE_IMAGE" &&
        "$full_promotion_requested" == "0" ]]; then
    echo "==> Fully promoting verified canonical BLUE recovery"
    echo "    Trusted recovery skips canary weights, analyses, and pauses"
    oc argo rollouts promote "$APP_NAME" \
      -n "$NAMESPACE" \
      --full >/dev/null
    full_promotion_requested=1
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring canonical BLUE baseline"

echo "==> Revalidating platform/GitOps dependencies"
bash scripts/deploy-canary-demo.sh

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Canonical BLUE canary baseline is Healthy and stable."
