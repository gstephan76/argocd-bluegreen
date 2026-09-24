# AI-gated Argo Rollouts demo on Red Hat OpenShift

This demo adapts the KubeCon Japan session **“AIOps: (near) Zero-Touch
Production Rollout Fixes”** and the upstream
`argoproj-labs/rollouts-plugin-metric-ai` project to this repository's
OpenShift GitOps workflow.

The decision path is:

```text
stable + canary logs / Kubernetes evidence
                  |
                  v
          metric-ai provider
                  |
                  v
           A2A Kubernetes agent
                  |
                  v
                 LLM
                  |
                  v
          promote / rollback
                  |
                  v
            Argo Rollouts
```

The base demo intentionally stops at AI-assisted rollout analysis and
promotion/rollback. GitHub source-code remediation is optional and disabled in
the base manifests.

## Sources and scenarios

- Video: `https://youtu.be/FH_fNfE90sU`
- Metric provider: `https://github.com/argoproj-labs/rollouts-plugin-metric-ai`
- Kubernetes AI agent: `https://github.com/kdubois/kubernetes-aiops-agent`
- Scenario application: `https://github.com/kdubois/argo-rollouts-quarkus-demo`

Scenario images:

```text
v1.stable       healthy scenario
v2.nullpointer  intentional NullPointerException scenario
```

The application includes its own request generator, so the canary produces
evidence before the AnalysisRun without a separate load generator.

## Requirements

- Red Hat OpenShift Container Platform 4.19+
- Red Hat OpenShift GitOps with `RolloutManager`
- `oc argo rollouts` CLI plugin
- amd64 nodes for the published metric-provider binary
- an OpenAI-compatible model endpoint reachable by the Kubernetes AI agent

The metric-provider installer supports the published releases used by this
demo:

```text
v0.0.1 -> built against Argo Rollouts v1.8.0
v1.9.0 -> built against Argo Rollouts v1.9.0
```

The installer keeps version selection dynamic because the RolloutManager is a
shared platform resource and controller/plugin compatibility matters. Override
the compatibility hint when required:

```bash
METRIC_AI_PLUGIN_VERSION=v0.0.1 \
bash scripts/install-metric-ai-plugin.sh
```

or:

```bash
METRIC_AI_PLUGIN_VERSION=v1.9.0 \
bash scripts/install-metric-ai-plugin.sh
```

## Model configuration

The metric plugin does not store model credentials. The Kubernetes AI agent
uses the runtime Secret `openshift-gitops/metric-ai-kubernetes-agent`.

OpenAI example:

```bash
export ANALYSIS_API_KEY='...'
export ANALYSIS_BASE_URL='https://api.openai.com/v1'
export ANALYSIS_MODEL='gpt-4o'
```

LiteLLM/vLLM example:

```bash
export ANALYSIS_API_KEY='dummy'
export ANALYSIS_BASE_URL='http://<service>:<port>/v1'
export ANALYSIS_MODEL='<model-name>'
```

Never commit model API keys to Git.

### Declarative GitHub bootstrap value

The upstream agent currently requires `github.token` to be non-empty even when
GitHub remediation is disabled. The base demo satisfies that startup contract
declaratively with:

```text
metric-ai-demo/agent/github-bootstrap-secret.yaml
```

which contains the inert value:

```text
metric-ai-remediation-disabled
```

It is deliberately not a credential and grants no GitHub access. No manual
`oc patch secret` step is required.

## Recommended presenter workflow

Use the launcher as the presentation interface:

```bash
cd ~/Documents/POCs/ArgoCD
./scripts/run-metric-ai-demo.sh --help
```

Before the audience arrives:

```bash
./scripts/run-metric-ai-demo.sh prepare
```

`prepare` delegates to the same robust pre-flight used by the scenario scripts:

```bash
bash scripts/preflight-metric-ai-demo.sh --remediate
```

The expected terminal condition is:

```text
============================================================
 Metric-AI pre-flight: READY
============================================================
```

For validation without remediation:

```bash
./scripts/run-metric-ai-demo.sh check
```

### Live presentation

Terminal 1 — presenter:

```bash
./scripts/run-metric-ai-demo.sh healthy
./scripts/run-metric-ai-demo.sh promote
./scripts/run-metric-ai-demo.sh failure
./scripts/run-metric-ai-demo.sh analysis
```

The scenario commands use lightweight state guards by default. To request the
complete robust validation/reconciliation pass before a scenario, add
`--preflight`:

```bash
./scripts/run-metric-ai-demo.sh healthy --preflight
./scripts/run-metric-ai-demo.sh failure --preflight
./scripts/run-metric-ai-demo.sh autofix --preflight
```

Terminal 2 — Rollout state:

```bash
./scripts/run-metric-ai-demo.sh watch
```

Terminal 3 — AI agent:

```bash
./scripts/run-metric-ai-demo.sh agent-logs
```

Optional split pane for the provider/controller side:

```bash
./scripts/run-metric-ai-demo.sh controller-logs
```

For rehearsal:

```bash
./scripts/run-metric-ai-demo.sh full
```

which performs:

```text
prepare -> healthy -> promote -> failure
```

and intentionally leaves the rejected failure scenario visible for inspection.

## Pre-flight behavior

`prepare` performs the complete pre-flight by default. `reset` performs robust
validation after restoring the trusted canonical baseline. `healthy`, `failure`,
and `autofix` use lightweight guards by default and run the complete pre-flight
only when `--preflight` is explicitly requested.

With `--remediate` it may safely reconcile:

```text
metric-ai RolloutManager plugin configuration
metric-ai-demo namespace
runtime AI-agent model Secret when ANALYSIS_API_KEY is supplied
declarative agent resources
Argo CD Application
Argo CD refresh/synchronization
Rollouts-controller pod-log RoleBinding
```

It deliberately stops on ambiguous or unsafe states such as a dirty tracked
tree, local/origin divergence, wrong repository/branch, unsupported
architecture, conflicting metric plugin, unfinished paused Rollout, degraded
Rollout, or unhealthy agent/model path.

The agent image is pinned for reproducible presentation runs:

```text
quay.io/kevindubois/kubernetes-agent@sha256:ec942d19e381d25435ca6184e4fe9d203208106567345b722c60108520fc0dd3
```

Image/configuration failures and CrashLoopBackOff are surfaced immediately by
the pre-flight.

## Underlying scripts

The launcher is only a thin presentation layer. The implementation scripts are:

```text
scripts/preflight-metric-ai-demo.sh
scripts/deploy-metric-ai-demo.sh
scripts/install-metric-ai-plugin.sh
scripts/start-metric-ai-healthy.sh
scripts/promote-metric-ai-stable.sh
scripts/start-metric-ai-failure.sh
scripts/show-metric-ai-analysis.sh
scripts/reset-metric-ai-demo.sh
scripts/cleanup-metric-ai-demo.sh
```

`deploy-metric-ai-demo.sh` is intentionally a compatibility wrapper around the
robust pre-flight so bootstrap/recovery logic is not duplicated.

## What to show in YAML

AnalysisTemplate:

```bash
bat metric-ai-demo/app/analysis-template.yaml
```

Core provider:

```yaml
provider:
  plugin:
    argoproj-labs/metric-ai:
      agentUrl: http://metric-ai-kubernetes-agent.openshift-gitops.svc.cluster.local:8080
      stableLabel: app=metric-ai-demo,role=stable
      canaryLabel: app=metric-ai-demo,role=canary
```

Rollout:

```bash
bat metric-ai-demo/app/rollout.yaml
```

Core steps:

```yaml
steps:
  - setWeight: 25
  - pause:
      duration: 20s
  - analysis:
      templates:
        - templateName: metric-ai-analysis
  - setWeight: 100
  - pause: {}
```

The baseline annotation is deliberately stable (`baseline-v1`). Scenario
scripts replace it with a unique run marker only when triggering a new
revision.

## Security and RBAC

The metric provider runs as a child process of the Argo Rollouts controller, so
it needs read access to stable/canary pod logs. The Role is Git-managed in
`metric-ai-demo/app/rbac.yaml`; pre-flight binds it to the controller
ServiceAccount discovered from the live Rollouts Deployment. The binding stays
runtime-discovered deliberately so a customized operator ServiceAccount does
not get hard-coded into Git.

The Kubernetes AI agent gets read-only diagnostic access to `metric-ai-demo`.
This adaptation does not grant `pods/exec` and does not grant application write
access.

The model credential Secret remains runtime-only. The inert GitHub bootstrap
Secret is checked in because it is not a credential.

## Optional GitHub remediation

The upstream agent can also create an issue or PR after a failed rollout. This
is disabled in the base demo.

Do not replace `metric-ai-github-bootstrap` in Git with a real token. To
demonstrate source remediation, use a writable fork of
`kdubois/argo-rollouts-quarkus-demo`, enable `githubUrl`/`baseBranch` in the
AnalysisTemplate, and supply the real GitHub token from an external Secret
manager or a private, untracked overlay that replaces the `GITHUB_TOKEN`
secretKeyRef.

The base repository intentionally contains no real GitHub credential.

## Reset and cleanup

Restore the known-good baseline:

```bash
./scripts/run-metric-ai-demo.sh reset
```

`reset` is a trusted recovery operation. After Git and Argo CD prove that the
live desired state is exactly `v1.stable` with marker `baseline-v1`, reset fully
promotes that canonical baseline while skipping canary pauses and AI analysis.
It then runs the robust pre-flight against the recovered baseline.

Clear only presentation history while keeping the demo installed:

```bash
./scripts/run-metric-ai-demo.sh clean-history
```

Delete the demo workload and isolated agent while leaving the shared metric
plugin installed:

```bash
./scripts/run-metric-ai-demo.sh cleanup
```

On a disposable environment, also remove the metric plugin:

```bash
./scripts/run-metric-ai-demo.sh cleanup-platform
```

Cleanup removes both the runtime model Secret and the declarative inert
`metric-ai-github-bootstrap` Secret from `openshift-gitops`.

## Diagnostics

Current Rollout:

```bash
./scripts/run-metric-ai-demo.sh status
```

Latest AI decision:

```bash
./scripts/run-metric-ai-demo.sh analysis
```

Candidate logs:

```bash
oc logs \
  -n metric-ai-demo \
  -l app=metric-ai-demo,role=canary \
  --tail=100
```

Stable logs:

```bash
oc logs \
  -n metric-ai-demo \
  -l app=metric-ai-demo,role=stable \
  --tail=100
```

Agent:

```bash
oc logs \
  -n openshift-gitops \
  deployment/metric-ai-kubernetes-agent \
  --tail=200
```

Provider/controller:

```bash
oc logs \
  -n openshift-gitops \
  deployment/argo-rollouts \
  --tail=300 |
rg 'metric-ai|AI metric|A2A|agent'
```

## Important behavior

The provider has no silent fallback if the agent cannot be reached or A2A
analysis fails: the AnalysisRun errors rather than silently approving the
candidate.

AI model decisions are probabilistic. The `v2.nullpointer` image is designed
to produce strong failure evidence, but the demo should display the actual
AnalysisRun result rather than claim the model must return a particular
decision.
