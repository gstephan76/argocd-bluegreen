#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAMESPACE="${APP_NAMESPACE:-knative-httpd}"
WORKER="${WORKER:-keda-async-worker}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
POLL_SECONDS="${POLL_SECONDS:-3}"
BACKLOG="${1:-}"

die(){ echo "ERROR: $*" >&2; exit 1; }
command -v oc >/dev/null 2>&1 || die "oc is required"
oc whoami >/dev/null 2>&1 || die "Not logged in to OpenShift"

[[ "${BACKLOG}" =~ ^[0-9]+$ ]] || die "Usage: $0 <non-negative-backlog>"

echo "==> Publishing demo_async_backlog=${BACKLOG}"
oc run keda-backlog-publisher \
  -n "${APP_NAMESPACE}" \
  --rm -i \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -- \
  sh -c "printf 'demo_async_backlog ${BACKLOG}\n' | curl --fail --silent --show-error --data-binary @- http://keda-demo-pushgateway:9091/metrics/job/knative-keda-demo" \
  >/dev/null

if (( BACKLOG == 0 )); then
  expected=0
else
  expected=$(( (BACKLOG + 9) / 10 ))
  (( expected > 5 )) && expected=5
  (( expected < 1 )) && expected=1
fi

echo "==> Waiting for worker target ~= ${expected} replica(s)"
deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  desired="$(oc get deployment "${WORKER}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  ready="$(oc get deployment "${WORKER}" -n "${APP_NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
  desired="${desired:-0}"
  ready="${ready:-0}"
  printf '    desired=%s ready=%s\n' "${desired}" "${ready}"

  if (( expected == 0 )); then
    [[ "${desired}" == "0" ]] && break
  else
    [[ "${desired}" == "${expected}" && "${ready}" == "${expected}" ]] && break
  fi
  sleep "${POLL_SECONDS}"
done

if (( SECONDS >= deadline )); then
  oc get scaledobject,hpa,deployment,pod -n "${APP_NAMESPACE}" || true
  die "Timed out waiting for KEDA scaling response"
fi

echo "KEDA reached the expected demo scale."
