#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"
AUTOFIX_REPO="gstephan76/argo-rollouts-quarkus-demo"
AUTOFIX_TIMEOUT_SECONDS="${AUTOFIX_TIMEOUT_SECONDS:-600}"
AUTOFIX_POLL_SECONDS="${AUTOFIX_POLL_SECONDS:-5}"

die(){ echo "ERROR: $*" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run this command from inside the repository"
cd "$ROOT"

run_autofix() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || \
    die "GITHUB_TOKEN is required for autofix and must be supplied through the environment"

  for c in oc rg date; do
    command -v "$c" >/dev/null 2>&1 || die "$c is required for autofix"
  done

  [[ -f metric-ai-demo/app/analysis-template-autofix.yaml ]] || \
    die "Declarative auto-fix AnalysisTemplate is missing"

  echo "==> Validating and reconciling the normal Metric-AI platform"
  bash scripts/preflight-metric-ai-demo.sh --remediate

  echo "==> Loading GITHUB_TOKEN into the existing runtime Secret"
  printf '%s' "$GITHUB_TOKEN" |
  oc create secret generic metric-ai-github-bootstrap \
    -n "$ARGOCD_NAMESPACE" \
    --from-file=github_token=/dev/stdin \
    --dry-run=client \
    -o yaml |
  oc apply -f - >/dev/null

  echo "==> Restarting AI agent so it reads the runtime GitHub credential"
  oc rollout restart deployment/"$AGENT_NAME" \
    -n "$ARGOCD_NAMESPACE" >/dev/null
  oc rollout status deployment/"$AGENT_NAME" \
    -n "$ARGOCD_NAMESPACE" \
    --timeout=180s >/dev/null

  echo "==> GitHub auto-fix target: ${AUTOFIX_REPO}"
  autofix_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  METRIC_AI_AUTOFIX=1 \
  METRIC_AI_SKIP_PREFLIGHT=1 \
    bash scripts/start-metric-ai-failure.sh

  echo
  echo "==> Waiting for asynchronous remediation pull request"
  deadline=$((SECONDS + AUTOFIX_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    agent_logs="$(
      oc logs \
        -n "$ARGOCD_NAMESPACE" \
        deployment/"$AGENT_NAME" \
        --since-time="$autofix_started" \
        2>/dev/null || true
    )"

    pr_url="$(
      printf '%s\n' "$agent_logs" |
      rg -o "https://github\\.com/${AUTOFIX_REPO}/pull/[0-9]+" |
      tail -1 || true
    )"

    if [[ -n "$pr_url" ]]; then
      echo
      echo "Auto-fix pull request created:"
      echo "  $pr_url"
      echo
      echo "Review and merge remain manual."
      return 0
    fi

    sleep "$AUTOFIX_POLL_SECONDS"
  done

  echo
  echo "No auto-fix pull request was observed before timeout." >&2
  echo "Recent AI-agent logs:" >&2
  oc logs \
    -n "$ARGOCD_NAMESPACE" \
    deployment/"$AGENT_NAME" \
    --since-time="$autofix_started" \
    --tail=160 >&2 || true
  die "Auto-fix remediation did not produce a pull request"
}

usage() {
  cat <<'EOF'
Metric-AI demo launcher

Usage:
  ./scripts/run-metric-ai-demo.sh <command>

Preparation:
  check             Validate without changing cluster state.
  prepare           Validate and safely remediate the complete demo.

Scenarios:
  healthy           Run the healthy AI-gated candidate.
  promote           Promote the AI-approved candidate at the final pause.
  failure           Run the intentional NullPointerException candidate.
  autofix           Run the failure and create an AI-generated GitHub fix PR.
  analysis          Show the latest AnalysisRun and AI decision.
  reset             Restore the v1.stable baseline.
  full              Rehearsal: prepare -> healthy -> promote -> failure.

Presentation:
  status            Show the current Rollout.
  watch             Continuously watch the Rollout.
  agent-logs        Follow Kubernetes AI-agent logs.
  controller-logs   Follow metric-ai / Argo Rollouts controller logs.

Cleanup:
  cleanup           Remove demo workload and isolated agent.
  cleanup-platform  Also remove the metric provider from RolloutManager.
EOF
}

case "${1:-}" in
  check)
    exec bash scripts/preflight-metric-ai-demo.sh
    ;;
  prepare)
    exec bash scripts/deploy-metric-ai-demo.sh
    ;;
  healthy)
    exec bash scripts/start-metric-ai-healthy.sh
    ;;
  promote)
    exec bash scripts/promote-metric-ai-stable.sh
    ;;
  failure)
    exec bash scripts/start-metric-ai-failure.sh
    ;;
  autofix)
    run_autofix
    ;;
  analysis)
    exec bash scripts/show-metric-ai-analysis.sh
    ;;
  reset)
    exec bash scripts/reset-metric-ai-demo.sh
    ;;
  full)
    bash scripts/deploy-metric-ai-demo.sh
    bash scripts/start-metric-ai-healthy.sh
    bash scripts/promote-metric-ai-stable.sh
    exec bash scripts/start-metric-ai-failure.sh
    ;;
  status)
    exec oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE"
    ;;
  watch)
    exec oc argo rollouts get rollout "$APP_NAME" -n "$NAMESPACE" --watch
    ;;
  agent-logs)
    exec oc logs \
      -n "$ARGOCD_NAMESPACE" \
      deployment/"$AGENT_NAME" \
      -f
    ;;
  controller-logs)
    command -v rg >/dev/null 2>&1 || die "rg is required"
    oc logs \
      -n "$ARGOCD_NAMESPACE" \
      deployment/argo-rollouts \
      -f |
    rg --line-buffered 'metric-ai|AI metric|A2A|agent'
    ;;
  cleanup)
    exec bash scripts/cleanup-metric-ai-demo.sh
    ;;
  cleanup-platform)
    exec bash scripts/cleanup-metric-ai-demo.sh --platform
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    die "Unknown command '$1'. Run: ./scripts/run-metric-ai-demo.sh --help"
    ;;
esac
