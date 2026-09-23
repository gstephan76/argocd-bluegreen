#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="metric-ai-demo/app/rollout.yaml"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed rg date; do command -v "$c" >/dev/null 2>&1 || die "$c not found"; done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run inside the repository"
cd "$ROOT"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"

git fetch origin
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

previous_rollout_revision="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
    2>/dev/null || true
)"

echo "==> Selecting healthy scenario"
sed -i -E \
  's#image: ghcr.io/kdubois/argo-rollouts-quarkus-demo:[^[:space:]]+#image: ghcr.io/kdubois/argo-rollouts-quarkus-demo:v1.stable#' \
  "$ROLLOUT_FILE"

rg -q 'demo-rollout-revision:' "$ROLLOUT_FILE" || \
  die "demo-rollout-revision annotation not found"

trigger="ai-healthy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "==> Triggering fresh revision: $trigger"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"$trigger\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
git commit -m "Trigger healthy AI-gated canary"
git push origin "$branch"

revision="$(git rev-parse HEAD)"

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${revision:0:12}"
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

echo "==> Waiting for Argo Rollouts to observe a new revision"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  rollout_revision="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
      2>/dev/null || true
  )"

  printf '    previous=%s current=%s\n' \
    "${previous_rollout_revision:-none}" \
    "${rollout_revision:-none}"

  [[ -n "$rollout_revision" &&
     "$rollout_revision" != "$previous_rollout_revision" ]] && break

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for a new Rollout revision"

echo "==> Waiting for AI-approved final pause (step 4)"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  printf '    phase=%s step=%s\n' "${phase:-unknown}" "${step:-unknown}"

  if [[ "$phase" == "Degraded" ]]; then
    echo
    bash scripts/show-metric-ai-analysis.sh || true
    die "AI analysis rejected the healthy candidate"
  fi

  [[ "$phase" == "Paused" && "$step" == "4" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for final AI-approved pause"

echo
bash scripts/show-metric-ai-analysis.sh
echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
echo
echo "AI analysis approved the candidate."
echo "Final manual approval:"
echo "  bash scripts/promote-metric-ai-stable.sh"
