#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="metric-ai-demo/app/rollout.yaml"

BASELINE_IMAGE="ghcr.io/kdubois/argo-rollouts-quarkus-demo:v1.stable"
BASELINE_MARKER="baseline-v1"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

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

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

echo "==> Restoring canonical stable baseline in Git"
sed -i -E \
  "s#image: ghcr.io/kdubois/argo-rollouts-quarkus-demo:[^[:space:]]+#image: ${BASELINE_IMAGE}#" \
  "$ROLLOUT_FILE"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"${BASELINE_MARKER}\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check

if git diff --cached --quiet; then
  echo "==> Git already declares the canonical stable baseline"
else
  git commit -m "Restore metric AI stable baseline"
  git push origin "$branch"
fi

revision="$(git rev-parse HEAD)"

oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for canonical stable baseline"
promotion_requested=0
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  got="$(oc get applications.argoproj.io "$APP_NAME" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"

  printf '    sync=%s revision=%s phase=%s step=%s stable=%s current=%s image=%s marker=%s\n' \
    "${sync:-unknown}" "${got:0:12}" "${phase:-unknown}" "${step:-unknown}" \
    "${stable:-none}" "${current:-none}" "${live_image:-unknown}" "${live_marker:-unknown}"

  if [[ "$sync" == "Synced" && "$got" == "$revision" ]]; then
    if [[ "$phase" == "Healthy" && -n "$stable" && "$stable" == "$current" ]]; then
      break
    fi

    if [[ "$phase" == "Paused" ]]; then
      if [[ "$step" == "4" &&
            "$live_image" == "$BASELINE_IMAGE" &&
            "$live_marker" == "$BASELINE_MARKER" &&
            -n "$current" &&
            "$stable" != "$current" ]]; then
        if (( promotion_requested == 0 )); then
          echo "==> Promoting canonical baseline at final pause"
          oc argo rollouts promote "$APP_NAME" -n "$NAMESPACE" >/dev/null
          promotion_requested=1
        fi
      else
        die "Refusing to auto-promote a paused non-canonical rollout during reset"
      fi
    fi
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out restoring stable baseline"

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "Canonical stable metric-AI baseline restored."
