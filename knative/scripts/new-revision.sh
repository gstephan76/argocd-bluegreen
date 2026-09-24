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
for c in oc curl date git sed awk grep; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || die "Run inside the argocd-bluegreen repository"
cd "$REPO_ROOT"
SERVICE_FILE="knative/app/service.yaml"

if ! git diff --quiet || ! git diff --cached --quiet; then
  die "Tracked Git changes exist"
fi

branch="$(git branch --show-current)"
[[ -n "$branch" ]] || die "Detached HEAD is not supported"
git fetch origin "$branch"
read -r behind ahead < <(git rev-list --left-right --count "origin/${branch}...HEAD")
(( behind == 0 && ahead == 0 )) || die "Local branch must match origin/${branch}"

oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"
head_revision="$(git rev-parse HEAD)"

sync="$(
  oc get applications.argoproj.io "$ARGOCD_APP" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true
)"
argo_revision="$(
  oc get applications.argoproj.io "$ARGOCD_APP" \
    -n "$ARGOCD_NAMESPACE" \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
)"
[[ "$sync" == "Synced" && "$argo_revision" == "$head_revision" ]] || \
  die "Knative Argo CD Application must be Synced to current Git HEAD; run knative/scripts/deploy.sh"

grep -q 'demo.knative.dev/version: baseline-v1' "$SERVICE_FILE" || \
  die "Git is not at the canonical V1 marker; run knative/scripts/deploy.sh"
grep -q 'name: httpd-page-v1' "$SERVICE_FILE" || \
  die "Git is not at the canonical V1 template; run knative/scripts/deploy.sh"
[[ "$(awk '/^  traffic:/{flag=1} flag{print}' "$SERVICE_FILE")" == $'  traffic:\n    - latestRevision: true\n      percent: 100' ]] || \
  die "Git traffic is not the canonical V1 baseline; run knative/scripts/deploy.sh"

ready="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
)"
[[ "$ready" == "True" ]] || die "Knative Service is not Ready; run knative/scripts/deploy.sh"

live_marker="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.metadata.annotations.demo\.knative\.dev/version}' 2>/dev/null || true
)"
live_configmap="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.volumes[0].configMap.name}' 2>/dev/null || true
)"
current_revision="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.latestReadyRevisionName}'
)"
served_revision="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[0].revisionName}'
)"
served_percent="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[0].percent}'
)"
existing_candidate="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' \
    2>/dev/null || true
)"

[[ "$live_marker" == "baseline-v1" && "$live_configmap" == "httpd-page-v1" ]] || \
  die "Live Service is not the canonical V1 template; run knative/scripts/deploy.sh"
[[ -n "$current_revision" &&
   "$served_revision" == "$current_revision" &&
   "$served_percent" == "100" &&
   -z "$existing_candidate" ]] || \
  die "Live traffic is not the settled 100% V1 baseline; run knative/scripts/deploy.sh"

main_url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.url}')"
curl_args=(--fail --silent --show-error --location)
[[ "$CURL_INSECURE" != "1" ]] || curl_args+=(--insecure)
curl "${curl_args[@]}" "$main_url" | grep -q 'Revision V1' || \
  die "Main URL is not serving V1"

trigger="v2-$(date -u +%Y%m%dT%H%M%SZ)-$$"
echo "==> Declaring fresh V2 candidate in Git: ${trigger}"

sed -i -E \
  "s#demo\.knative\.dev/version: .*#demo.knative.dev/version: ${trigger}#" \
  "$SERVICE_FILE"
sed -i -E \
  's#name: httpd-page-v1#name: httpd-page-v2#' \
  "$SERVICE_FILE"

tmp="${SERVICE_FILE}.tmp.$$"
awk '/^  traffic:/{exit} {print}' "$SERVICE_FILE" > "$tmp"
cat >> "$tmp" <<EOF
  traffic:
    - revisionName: ${current_revision}
      percent: 100
      tag: current
    - latestRevision: true
      percent: 0
      tag: candidate
EOF
mv "$tmp" "$SERVICE_FILE"

git add "$SERVICE_FILE"
git diff --cached --check
git commit -m "Create Knative V2 candidate"
git push origin "$branch"

desired_revision="$(git rev-parse HEAD)"
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
  argo_revision="$(
    oc get applications.argoproj.io "$ARGOCD_APP" \
      -n "$ARGOCD_NAMESPACE" \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
  )"
  [[ "$sync" == "Synced" && "$argo_revision" == "$desired_revision" ]] && break
  printf '    sync=%s revision=%s\n' "${sync:-unknown}" "${argo_revision:0:12}"
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for Argo CD"

echo "==> Waiting for a distinct Ready V2 revision and candidate tag"
deadline=$((SECONDS + READY_TIMEOUT))
candidate_revision=""
candidate_url=""
while (( SECONDS < deadline )); do
  ready="$(
    oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
  )"
  candidate_revision="$(
    oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
      -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' 2>/dev/null || true
  )"
  candidate_url="$(
    oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
      -o jsonpath='{.status.traffic[?(@.tag=="candidate")].url}' 2>/dev/null || true
  )"
  latest="$(
    oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
      -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true
  )"
  printf '    ready=%s current=%s candidate=%s latest=%s\n' \
    "${ready:-unknown}" "$current_revision" \
    "${candidate_revision:-pending}" "${latest:-pending}"

  [[ "$ready" == "True" &&
     -n "$candidate_revision" &&
     "$candidate_revision" != "$current_revision" &&
     "$candidate_revision" == "$latest" &&
     -n "$candidate_url" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for V2 candidate"

live_marker="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.spec.template.metadata.annotations.demo\.knative\.dev/version}' \
    2>/dev/null || true
)"
[[ "$live_marker" == "$trigger" ]] || die "Live V2 marker does not match Git trigger"

current_status_revision="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[?(@.tag=="current")].revisionName}'
)"
current_percent="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[?(@.tag=="current")].percent}'
)"
candidate_percent="$(
  oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
    -o jsonpath='{.status.traffic[?(@.tag=="candidate")].percent}'
)"
[[ "$current_status_revision" == "$current_revision" &&
   "$current_percent" == "100" &&
   "$candidate_percent" == "0" ]] || \
  die "Knative traffic did not converge to V1=100%, V2=0%"

curl "${curl_args[@]}" "$main_url" | grep -q 'Revision V1' || die "Main URL no longer serves V1"
curl "${curl_args[@]}" "$candidate_url" | grep -q 'Revision V2' || die "Candidate URL is not V2"

echo
echo "V2 candidate is Ready with 0% of normal traffic."
echo "V1 Revision : ${current_revision}"
echo "V2 Revision : ${candidate_revision}"
echo "Main URL    : ${main_url}"
echo "Candidate   : ${candidate_url}"
echo
echo "Next:"
echo "  knative/scripts/split-traffic.sh 50"
