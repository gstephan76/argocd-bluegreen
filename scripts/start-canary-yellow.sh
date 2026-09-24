#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-rollouts-canary-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-rollouts-canary-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-5}"
ROLLOUT_FILE="canary-demo/rollout.yaml"

BLUE_IMAGE="argoproj/rollouts-demo:blue"
YELLOW_IMAGE="argoproj/rollouts-demo:yellow"
BLUE_MARKER="baseline-blue"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed rg date awk sort tail cut; do
  command -v "$c" >/dev/null 2>&1 || die "$c not found"
done

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

head_revision="$(git rev-parse HEAD)"
oc get applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || \
  die "Argo CD Application is missing; run: bash scripts/prepare-canary-blue.sh"
oc get rollout "$APP_NAME" \
  -n "$NAMESPACE" >/dev/null 2>&1 || \
  die "Canary Rollout is missing; run: bash scripts/prepare-canary-blue.sh"

sync="$(
  oc get applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true
)"
live_revision="$(
  oc get applications.argoproj.io "$APP_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
)"
[[ "$sync" == "Synced" && "$live_revision" == "$head_revision" ]] || \
  die "Argo CD must be Synced to current Git HEAD before starting a canary"

desired_image="$(
  awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' \
    "$ROLLOUT_FILE"
)"
desired_marker="$(
  awk -F'"' '/demo-rollout-revision:/ {print $2; exit}' "$ROLLOUT_FILE"
)"
[[ "$desired_image" == "$BLUE_IMAGE" && "$desired_marker" == "$BLUE_MARKER" ]] || \
  die "Git is not at the canonical BLUE baseline; run: bash scripts/prepare-canary-blue.sh"

phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
live_image="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
live_marker="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true)"
current_image=""
[[ -z "$current" ]] || current_image="$(
  oc get pods -n "$NAMESPACE" \
    -l "rollouts-pod-template-hash=${current}" \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true
)"

[[ "$phase" == "Healthy" &&
   -n "$stable" &&
   "$stable" == "$current" &&
   "$live_image" == "$BLUE_IMAGE" &&
   "$live_marker" == "$BLUE_MARKER" &&
   "$current_image" == "$BLUE_IMAGE" ]] || \
  die "Live Rollout is not the settled canonical BLUE baseline; run: bash scripts/prepare-canary-blue.sh"

previous_rollout_revision="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
    2>/dev/null || true
)"

echo "==> Changing desired image BLUE -> YELLOW"
sed -i 's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:yellow#' "$ROLLOUT_FILE"

trigger="prometheus-$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "==> Triggering fresh canary revision: $trigger"
sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"$trigger\"#" \
  "$ROLLOUT_FILE"

git add "$ROLLOUT_FILE"
git diff --cached --check
git commit -m "Trigger Prometheus-gated yellow canary"
git push origin "$branch"

rev="$(git rev-parse HEAD)"

echo "==> Requesting Argo CD hard refresh"
oc annotate applications.argoproj.io "$APP_NAME" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD revision ${rev:0:12}"
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

  [[ "$sync" == "Synced" && "$got" == "$rev" ]] && break
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${got:0:12}"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for Argo Rollouts to observe the fresh YELLOW revision"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  rollout_revision="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
      2>/dev/null || true
  )"
  live_image="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true
  )"
  live_marker="$(
    oc get rollout "$APP_NAME" \
      -n "$NAMESPACE" \
      -o jsonpath='{.spec.template.metadata.annotations.demo-rollout-revision}' 2>/dev/null || true
  )"

  printf '    previous=%s current=%s image=%s marker=%s\n' \
    "${previous_rollout_revision:-none}" "${rollout_revision:-none}" \
    "${live_image:-unknown}" "${live_marker:-unknown}"

  [[ -n "$rollout_revision" &&
     "$rollout_revision" != "$previous_rollout_revision" &&
     "$live_image" == "$YELLOW_IMAGE" &&
     "$live_marker" == "$trigger" ]] && break

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for a new YELLOW Rollout revision"

echo "==> Automatic validation: 33% -> gate -> 66% -> gate -> 100% -> gate -> final pause"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  phase="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  step="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentStepIndex}' 2>/dev/null || true)"
  stable="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.stableRS}' 2>/dev/null || true)"
  current="$(oc get rollout "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
  current_image=""
  [[ -z "$current" ]] || current_image="$(
    oc get pods -n "$NAMESPACE" \
      -l "rollouts-pod-template-hash=${current}" \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true
  )"

  printf '    phase=%s step=%s stable=%s current=%s image=%s\n' \
    "${phase:-unknown}" "${step:-unknown}" \
    "${stable:-none}" "${current:-none}" "${current_image:-unknown}"

  if [[ "$phase" == "Degraded" ]]; then
    echo
    oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true
    echo
    oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" || true
    die "Prometheus gate failed; rollout did not progress"
  fi

  if [[ "$phase" == "Paused" &&
        "$step" == "6" &&
        -n "$current" &&
        "$stable" != "$current" &&
        "$current_image" == "$YELLOW_IMAGE" ]]; then
    break
  fi

  if [[ "$phase" == "Paused" && "$step" != "6" ]]; then
    die "Rollout paused at unexpected step ${step:-unknown}"
  fi

  if [[ "$phase" == "Healthy" &&
        -n "$stable" &&
        "$stable" == "$current" ]]; then
    die "Rollout became stable without reaching the expected final approval pause"
  fi

  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for the final approval pause"

rollout_revision="$(
  oc get rollout "$APP_NAME" \
    -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rollout\.argoproj\.io/revision}' \
    2>/dev/null || true
)"
[[ -n "$rollout_revision" ]] || die "Rollout revision is empty"

analysis_for_step() {
  local wanted_step="$1"
  oc get analysisrun \
    -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.rollout\.argoproj\.io/revision}{"|"}{.metadata.labels.rollouts-pod-template-hash}{"|"}{.metadata.labels.step-index}{"|"}{.metadata.ownerReferences[0].kind}{"|"}{.metadata.ownerReferences[0].name}{"|"}{.status.phase}{"|"}{.metadata.creationTimestamp}{"\n"}{end}' \
    2>/dev/null |
  awk -F'|' \
    -v rev="$rollout_revision" \
    -v hash="$current" \
    -v step="$wanted_step" \
    -v app="$APP_NAME" \
    '$2 == rev && $3 == hash && $4 == step && $5 == "Rollout" && $6 == app && $7 == "Successful" { print $8 "|" $1 }' |
  sort |
  tail -1 |
  cut -d'|' -f2-
}

for analysis_step in 1 3 5; do
  analysis_name="$(analysis_for_step "$analysis_step")"
  [[ -n "$analysis_name" ]] || \
    die "No Successful AnalysisRun is bound to current candidate at step ${analysis_step}"
  echo "==> Verified step ${analysis_step} AnalysisRun: ${analysis_name}"
done

echo
echo "==> AnalysisRuns"
oc get analysisrun -n "$NAMESPACE" --sort-by=.metadata.creationTimestamp || true

echo
oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"

echo
echo "All Prometheus gates passed at 33%, 66%, and 100% for the current YELLOW candidate."
echo "The canary is at the final approval pause (step 6) and is NOT stable yet."
echo
echo "Final manual approval:"
echo "  bash scripts/promote-canary-stable.sh"
