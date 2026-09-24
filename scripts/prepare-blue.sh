#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="bluegreen-demo/rollout.yaml"

BLUE_IMAGE="argoproj/rollouts-demo:blue"
BLUE_MARKER="baseline-blue"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed rg awk; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the argocd-bluegreen repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
oc argo rollouts version >/dev/null 2>&1 || die "Argo Rollouts oc plugin is required"
[[ -z "$(git status --short --untracked-files=no)" ]] || die "Tracked Git changes exist"

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local ${branch} must exactly match origin/${branch}"

rg -q 'demo-rollout-revision:' "$ROLLOUT_FILE" || \
  die "demo-rollout-revision annotation not found"
[[ "$(rg -c -- '- name: expected-color' "$ROLLOUT_FILE")" == "2" ]] || \
  die "Expected exactly two expected-color analysis arguments"

echo "==> Restoring canonical BLUE desired state in Git"
sed -i -E \
  's#image: argoproj/rollouts-demo:(blue|green)#image: argoproj/rollouts-demo:blue#' \
  "$ROLLOUT_FILE"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"${BLUE_MARKER}\"#" \
  "$ROLLOUT_FILE"
sed -i -E \
  '/- name: expected-color/{n;s#value: (blue|green)#value: blue#;}' \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already declares the canonical BLUE baseline"
else
  git commit -m "Restore canonical blue baseline"
  git push origin "$branch"
fi

revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  [[ "$sync" == "Synced" && "$got" == "$revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Recovering trusted canonical BLUE baseline"
full_promotion_requested=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stable_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current_hash="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  active_hash="$(oc get svc "${APP_NAME}-active" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_hash="$(oc get svc "${APP_NAME}-preview" -n "$NAMESPACE" -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  active_image=""
  current_image=""
  [[ -z "$active_hash" ]] || active_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${active_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  [[ -z "$current_hash" ]] || current_image="$(oc get pods -n "$NAMESPACE" -l "rollouts-pod-template-hash=${current_hash}" -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"

  printf '    phase=%s stable=%s current=%s active=%s preview=%s image=%s marker=%s\n' \
    "${phase:-unknown}" "${stable_hash:-none}" "${current_hash:-none}" \
    "${active_hash:-none}" "${preview_hash:-none}" \
    "${live_image:-unknown}" "${live_marker:-unknown}"

  [[ "$live_image" == "$BLUE_IMAGE" ]] || {
    sleep "$POLL_SECONDS"
    continue
  }
  [[ "$live_marker" == "$BLUE_MARKER" ]] || {
    sleep "$POLL_SECONDS"
    continue
  }

  if [[ "$phase" == "Healthy" &&
        -n "$stable_hash" &&
        "$stable_hash" == "$current_hash" &&
        "$active_hash" == "$stable_hash" &&
        "$preview_hash" == "$stable_hash" &&
        "$active_image" == "$BLUE_IMAGE" ]]; then
    break
  fi

  if [[ -n "$current_hash" &&
        "$current_image" == "$BLUE_IMAGE" &&
        "$full_promotion_requested" == "0" ]]; then
    echo "==> Fully promoting verified canonical BLUE recovery"
    echo "    Trusted recovery skips pre/post analysis and manual gates"
    oc argo rollouts promote "$APP_NAME" \
      -n "$NAMESPACE" \
      --full >/dev/null
    full_promotion_requested=1
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring canonical BLUE baseline"

echo "==> Running robust post-recovery platform/GitOps reconciliation"
bash scripts/deploy-demo.sh

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Canonical BLUE baseline is Healthy, active, preview, and stable."
