#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-metric-ai-demo}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
APP_NAME="${APP_NAME:-metric-ai-demo}"
AGENT_NAME="${AGENT_NAME:-metric-ai-kubernetes-agent}"

die(){ echo "ERROR: $*" >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || die "Run this command from inside the repository"
cd "$ROOT"

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
