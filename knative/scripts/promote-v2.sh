#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_APP="${ARGOCD_APP:-knative-httpd-demo}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
POLL_SECONDS="${POLL_SECONDS:-5}"
CURL_INSECURE="${CURL_INSECURE:-0}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl git awk grep; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

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
sync="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
argo_revision="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
[[ "$sync" == "Synced" && "$argo_revision" == "$head_revision" ]] || \
  die "Argo CD must be Synced to current Git HEAD before promotion"

desired_marker="$(awk '/demo\.knative\.dev\/version:/ {print $2; exit}' "$SERVICE_FILE")"
[[ "$desired_marker" == v2-* ]] || die "Git does not contain an active V2 scenario"

ready="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "$ready" == "True" ]] || die "Knative Service is not Ready"

live_marker="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo\.knative\.dev/version}' 2>/dev/null || true)"
[[ "$live_marker" == "$desired_marker" ]] || die "Live V2 marker does not match Git"

current="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].revisionName}' 2>/dev/null || true)"
candidate="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' 2>/dev/null || true)"
current_percent="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].percent}' 2>/dev/null || true)"
candidate_percent="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].percent}' 2>/dev/null || true)"
candidate_url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].url}' 2>/dev/null || true)"
latest="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true)"

[[ -n "$current" && -n "$candidate" && "$current" != "$candidate" ]] || \
  die "No distinct tagged V2 candidate exists; refusing fallback to latestReadyRevisionName"
[[ "$candidate" == "$latest" ]] || die "Tagged candidate is not the latest Ready V2 revision"
[[ "$current_percent" =~ ^[0-9]+$ && "$candidate_percent" =~ ^[0-9]+$ ]] || \
  die "Traffic percentages are not available"
(( current_percent > 0 && candidate_percent > 0 &&
   current_percent + candidate_percent == 100 )) || \
  die "Promote only after a real V1/V2 traffic split; run knative/scripts/split-traffic.sh first"
[[ -n "$candidate_url" ]] || die "Candidate URL is missing"

curl_args=(--fail --silent --show-error --location)
[[ "$CURL_INSECURE" != "1" ]] || curl_args+=(--insecure)
curl "${curl_args[@]}" "$candidate_url" | grep -q 'Revision V2' || \
  die "Tagged candidate does not serve Revision V2"

echo "==> Declaring exact V2 revision ${candidate} at 100% in Git"
tmp="${SERVICE_FILE}.tmp.$$"
awk '/^  traffic:/{exit} {print}' "$SERVICE_FILE" > "$tmp"
cat >> "$tmp" <<EOF
  traffic:
    - revisionName: ${candidate}
      percent: 100
EOF
mv "$tmp" "$SERVICE_FILE"

git add "$SERVICE_FILE"
git diff --cached --check
git commit -m "Promote Knative V2 to 100 percent"
git push origin "$branch"

desired_revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$ARGOCD_APP" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

echo "==> Waiting for exact declarative V2 promotion"
deadline=$((SECONDS + READY_TIMEOUT))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  argo_revision="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  ready="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  served="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[0].revisionName}' 2>/dev/null || true)"
  percent="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[0].percent}' 2>/dev/null || true)"
  printf '    sync=%s ready=%s revision=%s percent=%s\n' \
    "${sync:-unknown}" "${ready:-unknown}" "${served:-none}" "${percent:-?}"

  [[ "$sync" == "Synced" &&
     "$argo_revision" == "$desired_revision" &&
     "$ready" == "True" &&
     "$served" == "$candidate" &&
     "$percent" == "100" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for V2 promotion"

url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.url}')"
curl "${curl_args[@]}" "$url" | grep -q 'Revision V2' || \
  die "Main URL is not serving promoted V2"

echo
echo "V2 is serving 100% of normal traffic from Git-managed desired state."
echo "Revision: ${candidate}"
echo "URL     : ${url}"
echo
echo "Reset for another demo with:"
echo "  knative/scripts/deploy.sh"
