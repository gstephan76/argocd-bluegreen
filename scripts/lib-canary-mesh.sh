#!/usr/bin/env bash
# Shared bounded-I/O and diagnostics for the Service Mesh canary demo.
# Source this file; do not execute it directly.

KUBE_API_REQUEST_TIMEOUT="${KUBE_API_REQUEST_TIMEOUT:-15s}"
ARGO_ROLLOUTS_CLI_TIMEOUT_SECONDS="${ARGO_ROLLOUTS_CLI_TIMEOUT_SECONDS:-60}"
GIT_NETWORK_TIMEOUT_SECONDS="${GIT_NETWORK_TIMEOUT_SECONDS:-60}"
CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-5}"
CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-10}"

mesh_install_wrappers() {
  MESH_OC_BIN="$(type -P oc 2>/dev/null || true)"
  MESH_GIT_BIN="$(type -P git 2>/dev/null || true)"
  MESH_CURL_BIN="$(type -P curl 2>/dev/null || true)"
  [[ -n "$MESH_OC_BIN" ]] || { echo "ERROR: oc binary not found" >&2; return 1; }

  oc() {
    if [[ "${1:-}" == "argo" ]] && command -v timeout >/dev/null 2>&1; then
      timeout --foreground --signal=TERM "${ARGO_ROLLOUTS_CLI_TIMEOUT_SECONDS}s" "$MESH_OC_BIN" "$@"
    elif [[ "${1:-}" == "argo" ]]; then
      "$MESH_OC_BIN" "$@"
    else
      "$MESH_OC_BIN" --request-timeout="$KUBE_API_REQUEST_TIMEOUT" "$@"
    fi
  }

  if [[ -n "$MESH_GIT_BIN" ]]; then
    git() {
      case "${1:-}" in
        fetch|push)
          if command -v timeout >/dev/null 2>&1; then
            timeout --foreground --signal=TERM "${GIT_NETWORK_TIMEOUT_SECONDS}s" "$MESH_GIT_BIN" "$@"
          else
            "$MESH_GIT_BIN" "$@"
          fi
          ;;
        *) "$MESH_GIT_BIN" "$@" ;;
      esac
    }
  fi

  if [[ -n "$MESH_CURL_BIN" ]]; then
    curl() {
      "$MESH_CURL_BIN" --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" --max-time "$CURL_MAX_TIME_SECONDS" "$@"
    }
  fi
}

mesh_wait_argocd_revision() {
  local app="$1" namespace="$2" revision="$3" timeout_seconds="$4" poll_seconds="${5:-5}"
  local deadline=$((SECONDS + timeout_seconds)) sync health got operation conditions
  while (( SECONDS < deadline )); do
    sync="$(oc get applications.argoproj.io "$app" -n "$namespace" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(oc get applications.argoproj.io "$app" -n "$namespace" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    got="$(oc get applications.argoproj.io "$app" -n "$namespace" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    operation="$(oc get applications.argoproj.io "$app" -n "$namespace" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
    conditions="$(oc get applications.argoproj.io "$app" -n "$namespace" -o jsonpath='{range .status.conditions[*]}{.type}{":"}{.message}{" | "}{end}' 2>/dev/null || true)"
    printf '    sync=%s health=%s revision=%s operation=%s\n' "${sync:-unknown}" "${health:-unknown}" "${got:0:12}" "${operation:-none}"
    case "$operation" in Failed|Error) [[ -z "$conditions" ]] || printf '    conditions=%s\n' "$conditions" >&2; return 2 ;; esac
    if [[ "$conditions" == *"ComparisonError:"* || "$conditions" == *"InvalidSpecError:"* || "$conditions" == *"SyncError:"* ]]; then
      printf '    conditions=%s\n' "$conditions" >&2
      return 2
    fi
    [[ "$sync" == "Synced" && "$got" == "$revision" ]] && return 0
    sleep "$poll_seconds"
  done
  return 1
}

mesh_dump_diagnostics() {
  local ns="${NAMESPACE:-rollouts-mesh-canary-demo}" app="${APP_NAME:-rollouts-mesh-canary-demo}" argocd_ns="${ARGOCD_NAMESPACE:-openshift-gitops}"
  echo >&2; echo "===== mesh-canary diagnostics =====" >&2
  if oc get namespace "$ns" >/dev/null 2>&1; then
    echo "--- Rollout ---" >&2; oc get rollout.argoproj.io "$app" -n "$ns" -o wide >&2 2>/dev/null || true
    echo "--- Deployments / Pods / Services ---" >&2; oc get deployment,pod,service -n "$ns" -o wide >&2 2>/dev/null || true
    echo "--- Istio routing / Route / PodMonitor ---" >&2
    oc get gateway.networking.istio.io,virtualservice.networking.istio.io,route.route.openshift.io,podmonitor.monitoring.coreos.com -n "$ns" -o wide >&2 2>/dev/null || true
    echo "--- AnalysisRuns ---" >&2; oc get analysisrun.argoproj.io -n "$ns" --sort-by=.metadata.creationTimestamp >&2 2>/dev/null || true
    echo "--- Recent namespace events ---" >&2; oc get events -n "$ns" --sort-by=.lastTimestamp 2>/dev/null | tail -40 >&2 || true
  fi
  echo "--- Argo CD Application ---" >&2
  oc get applications.argoproj.io "$app" -n "$argocd_ns" -o jsonpath='sync={.status.sync.status} health={.status.health.status} revision={.status.sync.revision} operation={.status.operationState.phase}{"\n"}{range .status.conditions[*]}condition={.type}: {.message}{"\n"}{end}' >&2 2>/dev/null || true
  echo "===== end diagnostics =====" >&2
}

mesh__exit_handler() {
  local rc="$1"; trap - EXIT
  if (( rc != 0 )); then set +e; echo >&2; echo "ERROR: mesh-canary script exited with rc=${rc}" >&2; mesh_dump_diagnostics; fi
  exit "$rc"
}
mesh_enable_failure_diagnostics() { trap 'mesh__exit_handler "$?"' EXIT; }
