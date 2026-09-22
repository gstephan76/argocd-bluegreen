#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-bluegreen-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-bluegreen-demo}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
PREVIEW_ONLY=false

case "${1:-}" in
  "") ;;
  --preview-only) PREVIEW_ONLY=true ;;
  *)
    echo "Usage: $0 [--preview-only]" >&2
    exit 2
    ;;
esac

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need oc
need git
need sed

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${REPO_ROOT}" ]] || die "Run this script from inside the argocd-bluegreen Git repository."
cd "${REPO_ROOT}"

ROLLOUT_FILE="bluegreen-demo/rollout.yaml"
[[ -f "${ROLLOUT_FILE}" ]] || die "${ROLLOUT_FILE} not found."
[[ -f bluegreen-demo/analysis-template.yaml ]] || die "bluegreen-demo/analysis-template.yaml not found."

oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster."
oc argo rollouts version >/dev/null 2>&1 || \
  die "The Argo Rollouts oc plugin is required for promotion."

branch="$(git branch --show-current)"
[[ -n "${branch}" ]] || die "Detached HEAD is not supported."
git remote get-url origin >/dev/null 2>&1 || die "Git remote 'origin' is not configured."

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes are present. Commit/stash them before switching to GREEN."
fi

echo "==> Refreshing origin/${branch}"
git fetch origin

if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
  read -r behind ahead < <(
    git rev-list --left-right --count "origin/${branch}...HEAD"
  )
  if (( behind > 0 )); then
    die "Local ${branch} is behind origin/${branch} by ${behind} commit(s). Run: git pull --ff-only"
  fi
  if (( ahead > 0 )); then
    die "Local ${branch} is ahead of origin/${branch} by ${ahead} commit(s). Push or reconcile those commits before running this demo switch."
  fi
fi

current_image="$(awk '/^[[:space:]]*image:[[:space:]]+argoproj\/rollouts-demo:/ {print $2; exit}' \
  "${ROLLOUT_FILE}")"

case "${current_image}" in
  argoproj/rollouts-demo:blue)
    echo "==> Changing desired image BLUE -> GREEN in Git"
    sed -i \
      's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:green#' \
      "${ROLLOUT_FILE}"

    git add "${ROLLOUT_FILE}"
    git diff --cached --check
    git commit -m "Deploy green preview"
    git push origin "${branch}"

    ;;
  argoproj/rollouts-demo:green)
    echo "==> Git already requests GREEN; no image commit is required."
    ;;
  *)
    die "Unexpected demo image '${current_image}'. Expected :blue or :green."
    ;;
esac

desired_revision="$(git rev-parse HEAD)"

echo "==> Requesting Argo CD hard refresh for ${desired_revision:0:12}"
oc annotate applications.argoproj.io "${APP_NAME}" \
  -n "${ARGOCD_NAMESPACE}" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD to sync revision ${desired_revision:0:12}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  sync_status="$(oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  synced_revision="$(oc get applications.argoproj.io "${APP_NAME}" \
    -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"

  if [[ "${sync_status}" == "Synced" && "${synced_revision}" == "${desired_revision}" ]]; then
    echo "    Argo CD synced the GREEN Git revision."
    break
  fi

  printf '    sync=%s revision=%s\n' \
    "${sync_status:-unknown}" \
    "${synced_revision:0:12}"

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get applications.argoproj.io "${APP_NAME}" -n "${ARGOCD_NAMESPACE}" -o yaml || true
  die "Timed out waiting for Argo CD to sync the GREEN commit."
fi

active_hash="$(oc get svc "${APP_NAME}-active" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
active_image=""
if [[ -n "${active_hash}" ]]; then
  active_image="$(oc get pods \
    -n "${NAMESPACE}" \
    -l "rollouts-pod-template-hash=${active_hash}" \
    -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
fi

if [[ "${active_image}" == "argoproj/rollouts-demo:green" ]]; then
  active_host="$(oc get route "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"
  echo
  echo "GREEN is already active in production."
  echo "Production URL: https://${active_host}"
  exit 0
fi

echo "==> Waiting for GREEN to become the preview ReplicaSet"
deadline=$((SECONDS + TIMEOUT_SECONDS))
preview_hash=""
active_hash=""
while (( SECONDS < deadline )); do
  active_hash="$(oc get svc "${APP_NAME}-active" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"
  preview_hash="$(oc get svc "${APP_NAME}-preview" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"

  preview_image=""
  if [[ -n "${preview_hash}" ]]; then
    preview_image="$(oc get pods \
      -n "${NAMESPACE}" \
      -l "rollouts-pod-template-hash=${preview_hash}" \
      -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || true)"
  fi

  printf '    active=%s preview=%s image=%s\n' \
    "${active_hash:-none}" \
    "${preview_hash:-none}" \
    "${preview_image:-unknown}"

  if [[ -n "${active_hash}" &&
        -n "${preview_hash}" &&
        "${active_hash}" != "${preview_hash}" &&
        "${preview_image}" == "argoproj/rollouts-demo:green" ]]; then
    break
  fi

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" || true
  die "Timed out waiting for a distinct GREEN preview ReplicaSet."
fi

echo "==> Waiting for GREEN preview pods to become Ready"
oc wait \
  --for=condition=Ready \
  pod \
  -l "rollouts-pod-template-hash=${preview_hash}" \
  -n "${NAMESPACE}" \
  --timeout="${TIMEOUT_SECONDS}s"

echo "==> Waiting for pre-promotion AnalysisRun"
deadline=$((SECONDS + TIMEOUT_SECONDS))
analysis_name=""
analysis_status=""

while (( SECONDS < deadline )); do
  analysis_name="$(oc get rollout "${APP_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}' \
    2>/dev/null || true)"

  analysis_status="$(oc get rollout "${APP_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.status}' \
    2>/dev/null || true)"

  printf '    analysis=%s status=%s\n' \
    "${analysis_name:-pending}" \
    "${analysis_status:-pending}"

  case "${analysis_status}" in
    Successful)
      break
      ;;
    Failed|Error|Inconclusive)
      if [[ -n "${analysis_name}" ]]; then
        echo
        oc get analysisrun "${analysis_name}" -n "${NAMESPACE}" -o yaml || true
      fi
      echo
      oc get job,pod \
        -n "${NAMESPACE}" \
        -l app=bluegreen-demo-analysis \
        -o wide || true
      die "Pre-promotion analysis ended with status ${analysis_status}. Production remains on BLUE. Revert the GREEN Git commit before retrying."
      ;;
  esac

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" || true
  [[ -z "${analysis_name}" ]] || \
    oc get analysisrun "${analysis_name}" -n "${NAMESPACE}" -o yaml || true
  die "Timed out waiting for the pre-promotion analysis."
fi

echo "    AnalysisRun ${analysis_name} succeeded."

active_host="$(oc get route "${APP_NAME}" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"
preview_host="$(oc get route "${APP_NAME}-preview" \
  -n "${NAMESPACE}" \
  -o jsonpath='{.spec.host}')"

echo
echo "GREEN passed pre-promotion analysis and is ready for promotion."
echo "Production (still BLUE): https://${active_host}"
echo "Preview (GREEN)        : https://${preview_host}"
echo "AnalysisRun            : ${analysis_name}"
echo
oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}"

if [[ "${PREVIEW_ONLY}" == "true" ]]; then
  echo
  echo "Preview-only mode requested; GREEN has not been promoted."
  echo "The pre-promotion analysis has already succeeded."
  echo "Promote later with:"
  echo "  oc argo rollouts promote ${APP_NAME} -n ${NAMESPACE}"
  exit 0
fi

previous_stable_hash="${active_hash}"
echo
echo "==> Promoting GREEN to production"
oc argo rollouts promote "${APP_NAME}" -n "${NAMESPACE}"

echo "==> Waiting for the active Service to switch to GREEN hash ${preview_hash}"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  active_hash="$(oc get svc "${APP_NAME}-active" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' 2>/dev/null || true)"

  if [[ "${active_hash}" == "${preview_hash}" ]]; then
    break
  fi

  printf '    active=%s expected=%s\n' \
    "${active_hash:-none}" \
    "${preview_hash}"

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" || true
  die "Promotion command ran, but active Service did not switch to GREEN before timeout."
fi

echo "==> Waiting for post-promotion AnalysisRun"
deadline=$((SECONDS + TIMEOUT_SECONDS))
post_analysis_name=""
post_analysis_status=""

while (( SECONDS < deadline )); do
  post_analysis_name="$(oc get rollout "${APP_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.blueGreen.postPromotionAnalysisRunStatus.name}' \
    2>/dev/null || true)"

  post_analysis_status="$(oc get rollout "${APP_NAME}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.blueGreen.postPromotionAnalysisRunStatus.status}' \
    2>/dev/null || true)"

  printf '    post-analysis=%s status=%s\n' \
    "${post_analysis_name:-pending}" \
    "${post_analysis_status:-pending}"

  case "${post_analysis_status}" in
    Successful)
      break
      ;;
    Failed|Error|Inconclusive)
      echo
      [[ -z "${post_analysis_name}" ]] || \
        oc get analysisrun "${post_analysis_name}" -n "${NAMESPACE}" -o yaml || true
      echo
      oc get job,pod \
        -n "${NAMESPACE}" \
        -l app=bluegreen-demo-post-analysis \
        -o wide || true

      echo "==> Waiting for Argo Rollouts to restore the previous stable Service selector"
      rollback_deadline=$((SECONDS + TIMEOUT_SECONDS))
      while (( SECONDS < rollback_deadline )); do
        active_hash="$(oc get svc "${APP_NAME}-active" \
          -n "${NAMESPACE}" \
          -o jsonpath='{.spec.selector.rollouts-pod-template-hash}' \
          2>/dev/null || true)"

        [[ -n "${previous_stable_hash}" &&
           "${active_hash}" == "${previous_stable_hash}" ]] && break
        sleep "${POLL_SECONDS}"
      done

      oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" || true
      die "Post-promotion analysis ended with status ${post_analysis_status}. Argo Rollouts aborted the update and should restore production to the previous stable ReplicaSet."
      ;;
  esac

  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}" || true
  [[ -z "${post_analysis_name}" ]] || \
    oc get analysisrun "${post_analysis_name}" -n "${NAMESPACE}" -o yaml || true
  die "Timed out waiting for the post-promotion analysis."
fi

echo
echo "GREEN passed post-promotion analysis and is fully promoted."
echo "Production URL: https://${active_host}"
echo "Post AnalysisRun: ${post_analysis_name}"
echo
oc argo rollouts get rollout "${APP_NAME}" -n "${NAMESPACE}"

echo
echo "The previous BLUE ReplicaSet can now be scaled down by Argo Rollouts."
