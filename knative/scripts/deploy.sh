#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_APP="${ARGOCD_APP:-knative-httpd-demo}"
READY_TIMEOUT="${READY_TIMEOUT:-300}"
POLL_SECONDS="${POLL_SECONDS:-5}"
CURL_INSECURE="${CURL_INSECURE:-0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc git sed awk curl grep; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || die "Run inside the argocd-bluegreen repository"
cd "$REPO_ROOT"

SERVICE_FILE="knative/app/service.yaml"
INSTALL_SCRIPT="${REPO_ROOT}/knative/scripts/install-serverless.sh"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

replace_traffic_with_v1() {
  local tmp="${SERVICE_FILE}.tmp.$$"
  awk '/^  traffic:/{exit} {print}' "$SERVICE_FILE" > "$tmp"
  cat >> "$tmp" <<'EOF'
  traffic:
    - latestRevision: true
      percent: 100
EOF
  mv "$tmp" "$SERVICE_FILE"
}

echo "==> Restoring portable declarative V1 baseline in Git"
sed -i -E \
  's#demo\.knative\.dev/version: .*#demo.knative.dev/version: baseline-v1#' \
  "$SERVICE_FILE"
sed -i -E \
  's#name: httpd-page-v[12]#name: httpd-page-v1#' \
  "$SERVICE_FILE"
replace_traffic_with_v1

git add "$SERVICE_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already declares the canonical Knative V1 baseline"
else
  git commit -m "Restore Knative V1 baseline"
  git push origin "$branch"
fi

desired_revision="$(git rev-parse HEAD)"

serving_ready="$(
  oc get knativeserving knative-serving \
    -n knative-serving \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
    2>/dev/null || true
)"
if ! oc get crd services.serving.knative.dev >/dev/null 2>&1 ||
   [[ "$serving_ready" != "True" ]]; then
  echo "==> Knative Serving is absent or not Ready; bootstrapping Serverless"
  bash "$INSTALL_SCRIPT"
fi

oc get crd applications.argoproj.io >/dev/null 2>&1 || \
  die "Argo CD Application CRD is missing; install OpenShift GitOps first"

echo "==> Applying Knative Argo CD Application"
oc apply -f argocd/application-knative.yaml >/dev/null
oc annotate applications.argoproj.io "$ARGOCD_APP" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for Argo CD exact revision ${desired_revision:0:12}"
deadline=$((SECONDS + READY_TIMEOUT))
while (( SECONDS < deadline )); do
  sync="$(
    oc get applications.argoproj.io "$ARGOCD_APP" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || true
  )"
  revision="$(
    oc get applications.argoproj.io "$ARGOCD_APP" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
  )"
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${revision:0:12}"
  [[ "$sync" == "Synced" && "$revision" == "$desired_revision" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

if ! oc wait --for=condition=Ready "ksvc/${SERVICE_NAME}" \
  -n "$APP_NAMESPACE" \
  --timeout="${READY_TIMEOUT}s"; then
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o yaml || true
  oc get revision,pod -n "$APP_NAMESPACE" -o wide || true
  die "Knative Service did not become Ready"
fi

live_marker="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.metadata.annotations.demo\.knative\.dev/version}' \
    2>/dev/null || true
)"
live_configmap="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}' \
    2>/dev/null || true
)"
latest="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.latestReadyRevisionName}' \
    2>/dev/null || true
)"
served="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[0].revisionName}' \
    2>/dev/null || true
)"
percent="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[0].percent}' \
    2>/dev/null || true
)"

[[ "$live_marker" == "baseline-v1" ]] || die "Live Knative marker is not baseline-v1"
[[ "$live_configmap" == "httpd-page-v1" ]] || die "Live Knative template is not V1"
[[ -n "$latest" && "$served" == "$latest" && "$percent" == "100" ]] || \
  die "Knative traffic did not converge to 100% of the V1 latest revision"

URL="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.url}')"
curl_args=(--fail --silent --show-error --location)
[[ "$CURL_INSECURE" != "1" ]] || curl_args+=(--insecure)
curl "${curl_args[@]}" "$URL" | grep -q 'Revision V1' || \
  die "Main URL is not serving Revision V1"

echo
echo "Canonical GitOps-managed V1 baseline is Ready."
echo "Revision: ${latest}"
echo "URL     : ${URL}"
echo
echo "Verify:"
echo "  ${REPO_ROOT}/knative/scripts/verify.sh"
echo
echo "Scale-to-zero / cold activation:"
echo "  ${REPO_ROOT}/knative/scripts/verify.sh --scale-to-zero"
echo
echo "Create a declarative V2 candidate:"
echo "  ${REPO_ROOT}/knative/scripts/new-revision.sh"
