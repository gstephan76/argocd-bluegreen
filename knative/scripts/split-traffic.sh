#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
SERVICE_NAME="${SERVICE_NAME:-httpd-single-page}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_APP="${ARGOCD_APP:-knative-httpd-demo}"
READY_TIMEOUT="${READY_TIMEOUT:-180}"
POLL_SECONDS="${POLL_SECONDS:-5}"
CURL_INSECURE="${CURL_INSECURE:-0}"
SAMPLES="${SAMPLES:-20}"
CANDIDATE_PERCENT="${1:-50}"

die(){ echo "ERROR: $*" >&2; exit 1; }
for c in oc curl git awk seq grep; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done

[[ "$CANDIDATE_PERCENT" =~ ^[0-9]+$ ]] || die "Percentage must be an integer"
(( CANDIDATE_PERCENT >= 1 && CANDIDATE_PERCENT <= 99 )) || die "Percentage must be 1..99"
current_percent=$((100 - CANDIDATE_PERCENT))

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
  die "Argo CD must be Synced to current Git HEAD"

desired_marker="$(awk '/demo\.knative\.dev\/version:/ {print $2; exit}' "$SERVICE_FILE")"
[[ "$desired_marker" == v2-* ]] || die "Git does not contain an active V2 scenario"

ready="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
[[ "$ready" == "True" ]] || die "Knative Service is not Ready"

live_marker="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.spec.template.metadata.annotations.demo\.knative\.dev/version}' 2>/dev/null || true)"
[[ "$live_marker" == "$desired_marker" ]] || die "Live V2 marker does not match Git"

current_revision="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].revisionName}' 2>/dev/null || true)"
candidate_revision="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' 2>/dev/null || true)"
current_url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].url}' 2>/dev/null || true)"
candidate_url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].url}' 2>/dev/null || true)"
latest="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.latestReadyRevisionName}' 2>/dev/null || true)"

[[ -n "$current_revision" && -n "$candidate_revision" && "$current_revision" != "$candidate_revision" ]] || \
  die "Distinct current/candidate revisions are required; run knative/scripts/new-revision.sh"
[[ "$candidate_revision" == "$latest" ]] || die "Candidate is not the latest Ready V2 revision"
[[ -n "$current_url" && -n "$candidate_url" ]] || die "Tagged current/candidate URLs are missing"

curl_args=(--fail --silent --show-error --location)
[[ "$CURL_INSECURE" != "1" ]] || curl_args+=(--insecure)
curl "${curl_args[@]}" "$current_url" | grep -q 'Revision V1' || die "Current tag is not V1"
curl "${curl_args[@]}" "$candidate_url" | grep -q 'Revision V2' || die "Candidate tag is not V2"

echo "==> Declaring Knative traffic split in Git: V1 ${current_percent}% / V2 ${CANDIDATE_PERCENT}%"
tmp="${SERVICE_FILE}.tmp.$$"
awk '/^  traffic:/{exit} {print}' "$SERVICE_FILE" > "$tmp"
cat >> "$tmp" <<EOF
  traffic:
    - revisionName: ${current_revision}
      percent: ${current_percent}
      tag: current
    - revisionName: ${candidate_revision}
      percent: ${CANDIDATE_PERCENT}
      tag: candidate
EOF
mv "$tmp" "$SERVICE_FILE"

git add "$SERVICE_FILE"
git diff --cached --check
if git diff --cached --quiet; then
  echo "==> Git already requests this exact traffic split"
else
  git commit -m "Set Knative V1 V2 traffic split"
  git push origin "$branch"
fi

desired_revision="$(git rev-parse HEAD)"
oc annotate applications.argoproj.io "$ARGOCD_APP" \
  -n "$ARGOCD_NAMESPACE" \
  argocd.argoproj.io/refresh=hard \
  --overwrite >/dev/null

deadline=$((SECONDS + READY_TIMEOUT))
while (( SECONDS < deadline )); do
  sync="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  argo_revision="$(oc get applications.argoproj.io "$ARGOCD_APP" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
  ready="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  got_current="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].revisionName}' 2>/dev/null || true)"
  got_candidate="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].revisionName}' 2>/dev/null || true)"
  got_current_percent="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="current")].percent}' 2>/dev/null || true)"
  got_candidate_percent="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.traffic[?(@.tag=="candidate")].percent}' 2>/dev/null || true)"

  printf '    sync=%s ready=%s V1=%s%% V2=%s%%\n' \
    "${sync:-unknown}" "${ready:-unknown}" \
    "${got_current_percent:-?}" "${got_candidate_percent:-?}"

  [[ "$sync" == "Synced" &&
     "$argo_revision" == "$desired_revision" &&
     "$ready" == "True" &&
     "$got_current" == "$current_revision" &&
     "$got_candidate" == "$candidate_revision" &&
     "$got_current_percent" == "$current_percent" &&
     "$got_candidate_percent" == "$CANDIDATE_PERCENT" ]] && break
  sleep "$POLL_SECONDS"
done
(( SECONDS < deadline )) || die "Timed out waiting for declarative traffic split"

url="$(oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.url}')"
v1=0; v2=0; other=0
for _ in $(seq 1 "$SAMPLES"); do
  body="$(curl "${curl_args[@]}" "$url")"
  if [[ "$body" == *"Revision V1"* ]]; then
    v1=$((v1 + 1))
  elif [[ "$body" == *"Revision V2"* ]]; then
    v2=$((v2 + 1))
  else
    other=$((other + 1))
  fi
done

echo
oc get ksvc "$SERVICE_NAME" -n "$APP_NAMESPACE" \
  -o jsonpath='{range .status.traffic[*]}{.percent}{"% -> "}{.revisionName}{" tag="}{.tag}{"\n"}{end}'
echo "Observed ${SAMPLES} requests: V1=${v1} V2=${v2} other=${other}"
echo "Small samples are not expected to match the configured percentage exactly."
