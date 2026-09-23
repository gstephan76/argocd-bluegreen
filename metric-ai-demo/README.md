# AI-gated Argo Rollouts demo on Red Hat OpenShift

This demo adapts the KubeCon Japan session **“AIOps: (near) Zero-Touch
Production Rollout Fixes”** and the upstream
`argoproj-labs/rollouts-plugin-metric-ai` project to this repository's
OpenShift GitOps workflow.

The key change from the existing Prometheus Canary demo is the decision source:

```text
existing canary:
Prometheus/Blackbox -> fixed conditions -> Argo Rollouts

metric-ai demo:
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
promotion/rollback. Automated GitHub remediation is documented separately and
disabled by default.

## Source projects

- Video: `https://youtu.be/FH_fNfE90sU`
- Metric provider: `https://github.com/argoproj-labs/rollouts-plugin-metric-ai`
- Kubernetes AI agent: `https://github.com/kdubois/kubernetes-aiops-agent`
- Scenario application: `https://github.com/kdubois/argo-rollouts-quarkus-demo`

The upstream application provides:

```text
v1.stable       healthy scenario
v2.nullpointer  intentional NullPointerException scenario
```

It also includes a built-in request generator, so the canary produces
application evidence before the AnalysisRun without a separate load generator.

## OpenShift-specific simplification

The upstream demo includes additional traffic-routing pieces. This repository
uses a basic four-replica canary so the audience can focus on the AI metric
provider:

```text
4 stable pods
     |
new revision
     |
setWeight 25
     |
3 stable + 1 canary
     |
20 second evidence window
     |
AI AnalysisRun
     |
     +-- Failed -----> automatic abort / stable remains
     |
     +-- Successful -> setWeight 100 -> manual approval -> stable
```

No Gateway API plugin is required.

## Requirements

- Red Hat OpenShift Container Platform 4.19+
- Red Hat OpenShift GitOps with `RolloutManager`
- `oc argo rollouts` CLI plugin
- amd64 nodes for the published upstream metric-plugin binary
- an OpenAI-compatible model endpoint reachable by the Kubernetes AI agent

The upstream metric provider currently has two published binary releases used
by this demo:

```text
v0.0.1 -> built against Argo Rollouts v1.8.0
v1.9.0 -> built against Argo Rollouts v1.9.0
```

The installer uses the local Rollouts CLI version as a compatibility hint. You
can override it explicitly:

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

The metric plugin does not store the model API key. The Kubernetes AI agent
does.

Example OpenAI configuration:

```bash
export ANALYSIS_API_KEY='...'
export ANALYSIS_BASE_URL='https://api.openai.com/v1'
export ANALYSIS_MODEL='gpt-4o'
```

Example LiteLLM/vLLM-compatible endpoint:

```bash
export ANALYSIS_API_KEY='dummy'
export ANALYSIS_BASE_URL='http://<service>:<port>/v1'
export ANALYSIS_MODEL='<model-name>'
```

Never commit API keys to Git.

# Live demo: terminals and scripts

Use three terminals.

## Terminal 1 — operator/control

Deploy the platform pieces, agent, and GitOps application:

```bash
cd ~/Documents/POCs/ArgoCD

bash scripts/deploy-metric-ai-demo.sh
```

### Healthy path

```bash
bash scripts/start-metric-ai-healthy.sh
```

Expected:

```text
25% canary
   |
AI compares stable/canary evidence
   |
AnalysisRun Successful
   |
100% candidate
   |
final manual pause
```

Inspect the AI decision:

```bash
bash scripts/show-metric-ai-analysis.sh
```

Then explicitly approve the candidate:

```bash
bash scripts/promote-metric-ai-stable.sh
```

### Failure path

Restore the known-good baseline first when necessary:

```bash
bash scripts/reset-metric-ai-demo.sh
```

Start the intentional NullPointerException candidate:

```bash
bash scripts/start-metric-ai-failure.sh
```

Expected:

```text
25% broken canary
      |
AI AnalysisRun
      |
promotion=false
      |
AnalysisRun Failed
      |
Rollout aborts
      |
previous stable ReplicaSet remains
```

Inspect the real decision:

```bash
bash scripts/show-metric-ai-analysis.sh
```

## Terminal 2 — Rollout state

Start this before either scenario:

```bash
oc argo rollouts get rollout metric-ai-demo \
  -n metric-ai-demo \
  --watch
```

## Terminal 3 — AI agent

```bash
oc logs \
  -n openshift-gitops \
  deployment/metric-ai-kubernetes-agent \
  -f
```

For the metric-plugin side, use a split pane:

```bash
oc logs \
  -n openshift-gitops \
  deployment/argo-rollouts \
  -f |
rg --line-buffered 'metric-ai|AI metric|A2A|agent'
```

Presentation rhythm:

```text
Terminal 1                    Terminal 2                 Terminal 3
----------                    ----------                 ----------
deploy-metric-ai-demo.sh      stable rollout            agent ready
start healthy/failure         25% canary                A2A/AI analysis
show analysis                 success/failure           reasoning
promote healthy candidate     candidate -> stable
```

# What to show in YAML

The core AnalysisTemplate is deliberately small:

```bash
bat metric-ai-demo/app/analysis-template.yaml
```

Core provider configuration:

```yaml
provider:
  plugin:
    argoproj-labs/metric-ai:
      agentUrl: http://metric-ai-kubernetes-agent.openshift-gitops.svc.cluster.local:8080
      stableLabel: app=metric-ai-demo,role=stable
      canaryLabel: app=metric-ai-demo,role=canary
      extraPrompt: >-
        Compare the canary against the stable pods...
```

The Rollout is equally explicit:

```bash
bat metric-ai-demo/app/rollout.yaml
```

The significant steps are:

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

# Security and RBAC

The metric plugin runs as a child process of the Argo Rollouts controller.
Therefore it inherits that controller's Kubernetes identity. The deploy script
discovers the controller ServiceAccount and grants only:

```text
get/list pods
get pods/log
```

inside `metric-ai-demo`.

The Kubernetes AI agent gets read-only diagnostic access to the same namespace.
This adaptation does not grant `pods/exec` and does not grant write access to
application resources.

# Optional GitHub remediation

The conference workflow and upstream agent can also create an issue or PR after
a failed rollout. This is intentionally disabled by default.

The source code being analyzed belongs to the upstream demo application, so
giving the agent write access to this `argocd-bluegreen` repository would not
give it the correct source tree to repair.

To demonstrate remediation safely:

1. Fork `kdubois/argo-rollouts-quarkus-demo`.
2. Enable in `metric-ai-demo/app/analysis-template.yaml`:

```yaml
githubUrl: https://github.com/<your-user>/argo-rollouts-quarkus-demo
baseBranch: main
```

3. Export a fine-grained token that can write to that fork:

```bash
export GITHUB_TOKEN='...'
```

4. Rerun:

```bash
bash scripts/deploy-metric-ai-demo.sh
```

Review any generated PR before merging it.

# Reset and cleanup

After the intentionally failed canary:

```bash
bash scripts/reset-metric-ai-demo.sh
```

Delete the demo and isolated AI agent while keeping the metric plugin installed:

```bash
bash scripts/cleanup-metric-ai-demo.sh
```

On a disposable environment, remove the metric plugin configuration as well:

```bash
bash scripts/cleanup-metric-ai-demo.sh --platform
```

# Diagnostics

Current rollout:

```bash
oc argo rollouts get rollout metric-ai-demo \
  -n metric-ai-demo
```

AnalysisRuns:

```bash
oc get analysisrun \
  -n metric-ai-demo \
  --sort-by=.metadata.creationTimestamp
```

AI decision:

```bash
bash scripts/show-metric-ai-analysis.sh
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
oc get deployment metric-ai-kubernetes-agent \
  -n openshift-gitops

oc logs deployment/metric-ai-kubernetes-agent \
  -n openshift-gitops \
  --tail=200
```

Plugin/controller:

```bash
oc logs deployment/argo-rollouts \
  -n openshift-gitops \
  --tail=300 |
rg 'metric-ai|AI metric|A2A|agent'
```

## Important behavior

The plugin has no silent fallback if the agent cannot be reached or A2A
analysis fails: the AnalysisRun errors rather than silently approving the
candidate.

AI model decisions are probabilistic. The `v2.nullpointer` image is designed
to produce strong failure evidence, but the demo should always display the
actual AnalysisRun result rather than claiming the model must return a
particular decision.
