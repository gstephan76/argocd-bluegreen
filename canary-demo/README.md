# OpenShift GitOps + Argo Rollouts Canary Demo

This demo implements a Prometheus-gated Argo Rollouts canary on OpenShift GitOps.

The committed baseline is BLUE with marker `baseline-blue`. A YELLOW scenario is
created only after the scripts prove that Git, Argo CD, and the live Rollout are
all on that settled baseline. The rollout then advances automatically through
33%, 66%, and 100% only after each inline AnalysisRun succeeds. After the 100%
gate succeeds, the Rollout pauses for one explicit operator approval before the
candidate ReplicaSet is declared stable.

No second OpenShift Route is created. The existing public Route remains the user-facing application Route.

## Rollout flow

Six replicas make the basic canary weights map cleanly to pod counts:

```text
33%  -> 2 canary + 4 stable
66%  -> 4 canary + 2 stable
100% -> 6 canary
```

The seven Rollout steps are:

```text
0  setWeight 33
1  analysis
2  setWeight 66
3  analysis
4  setWeight 100
5  analysis
6  final manual pause
```

The complete flow is:

```text
fresh canary revision
        |
        v
      33%
        |
  3 x HTTP 200
        |
        v
      66%
        |
  3 x HTTP 200
        |
        v
      100%
        |
  3 x HTTP 200
        |
        v
 FINAL MANUAL PAUSE
     step 6/7
        |
 operator promotes
        |
        v
 candidate becomes STABLE
```

If any inline analysis fails, the rollout does not progress to the next weight.

## Who generates the HTTP traffic?

No browser refresh and no manual `curl` is required for the rollout to progress.

OpenShift user-workload Prometheus scrapes the Blackbox Exporter through the `ServiceMonitor` every five seconds:

```text
OpenShift user-workload Prometheus
        |
        | scrape every 5 seconds
        v
Blackbox Exporter /probe
        |
        | performs a real HTTP GET /color
        v
rollouts-canary-demo-canary Service
        |
        v
current canary ReplicaSet only
```

The `ServiceMonitor` contains:

```yaml
interval: 5s
path: /probe
params:
  module:
    - http_200
  target:
    - http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

Each Prometheus scrape therefore causes Blackbox Exporter to make a real HTTP request to the canary-only Service.

Blackbox returns metrics such as:

```text
probe_http_status_code 200
probe_success 1
```

Argo Rollouts does not generate the application traffic. Its AnalysisRun queries Prometheus/Thanos every ten seconds and evaluates the metrics collected by Prometheus.

The AnalysisTemplate requires all three measurements to succeed for both:

```text
probe_http_status_code == 200
probe_success == 1
```

With `failureLimit: 0`, the first failed measurement fails that metric. Therefore
all three measurements for both metrics must succeed before the rollout advances.

## Why the internal canary Service is used

The promotion gate probes:

```text
http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

Argo Rollouts owns the selector of this Service and adds the current canary ReplicaSet hash. Conceptually:

```yaml
selector:
  app: rollouts-canary-demo
  rollouts-pod-template-hash: <current-canary-hash>
```

Therefore the probe reaches only the current canary ReplicaSet. Stable pods cannot mask a broken candidate.

The normal application Service and the existing public Route are left unchanged. During a gradual rollout they can serve both stable and canary pods, which is correct for application traffic but unsuitable as the promotion health gate.

## Scripted demo

### Live session: scripts and terminals

Use three terminals for the clearest presentation.

**Terminal 1 — operator/control**

Run the Canary workflow here, in this exact order:

```bash
cd ~/Documents/POCs/ArgoCD

bash scripts/deploy-canary-demo.sh
bash scripts/prepare-canary-blue.sh
bash scripts/start-canary-yellow.sh

# Wait until the script reaches the final manual pause at step 6/7.

bash scripts/promote-canary-stable.sh
```

`start-canary-yellow.sh` drives the rollout automatically through the 33%,
66%, and 100% Prometheus gates. No operator command is required between those
stages.

**Terminal 2 — live Rollout view**

Start this before `start-canary-yellow.sh` and leave it running:

```bash
cd ~/Documents/POCs/ArgoCD

oc argo rollouts get rollout rollouts-canary-demo \
  -n rollouts-canary-demo \
  --watch
```

**Terminal 3 — Prometheus-gated AnalysisRuns**

This terminal is optional but useful for showing each analysis gate:

```bash
watch -n 2 '
oc get analysisrun \
  -n rollouts-canary-demo \
  --sort-by=.metadata.creationTimestamp
'
```

The intended session is:

```text
Terminal 1                         Terminal 2                  Terminal 3
----------                         ----------                  ----------
deploy-canary-demo.sh              Rollout status              AnalysisRuns
start-canary-yellow.sh             33% -> 66% -> 100%         gate results
                                   final pause step 6/7
promote-canary-stable.sh           candidate -> stable
```

The only manual rollout decision is the final
`promote-canary-stable.sh` after the rollout reaches step `6/7`.

Run from the repository root:

```bash
cd ~/Documents/POCs/ArgoCD
```

### 1. Deploy or reconcile

```bash
bash scripts/deploy-canary-demo.sh
```

This command bootstraps the RolloutManager and monitoring dependencies when
needed, creates/reconciles the Argo CD Application, and waits for the exact Git
revision. It does not treat an arbitrary scenario state as the presentation
baseline.

### 2. Establish the canonical BLUE baseline

```bash
bash scripts/prepare-canary-blue.sh
```

This is the trusted reset/recovery command. It restores `:blue` plus
`baseline-blue` in Git, bootstraps a missing Application through
`deploy-canary-demo.sh`, and may use `oc argo rollouts promote --full` only
after the live desired state is proven to be that exact canonical BLUE state.
It returns only when the Rollout is `Healthy` with `stableRS == currentPodHash`.

### 3. Start a fresh YELLOW canary revision

```bash
bash scripts/start-canary-yellow.sh
```

The script refuses to mutate Git unless the cluster is on the settled BLUE
baseline and Argo CD is synchronized to the current Git HEAD. It creates a
fresh Git-managed YELLOW pod-template revision and waits while the rollout
progresses automatically:

```text
33% -> 3/3 successful Prometheus measurements
66% -> 3/3 successful Prometheus measurements
100% -> 3/3 successful Prometheus measurements
step 6/7 -> final pause
```

Before returning, it binds the successful AnalysisRuns at steps 1, 3, and 5 to
the current Rollout revision and `currentPodHash`.

### 4. Final operator approval

After the script reports that all three Prometheus gates passed:

```bash
bash scripts/promote-canary-stable.sh
```

Promotion is bound to clean/synchronized Git, exact Argo CD HEAD, the YELLOW
candidate hash, final step `6`, and the three successful AnalysisRuns belonging
to that candidate. This is the only manual approval in the rollout.

## Manual demo without helper scripts

The following performs the same demo without `deploy-canary-demo.sh`, `start-canary-yellow.sh`, or `promote-canary-stable.sh`.

Run all commands from the repository root:

```bash
cd ~/Documents/POCs/ArgoCD
```

### 1. Verify access and required APIs

```bash
oc whoami

oc get crd applications.argoproj.io
oc get crd argocds.argoproj.io
oc get crd rollouts.argoproj.io
oc get crd rolloutmanagers.argoproj.io
oc get crd analysistemplates.argoproj.io
oc get crd analysisruns.argoproj.io
oc get crd servicemonitors.monitoring.coreos.com

oc argo rollouts version
```

### 2. Enable user-workload monitoring

Inspect existing cluster monitoring configuration first:

```bash
oc get configmap cluster-monitoring-config   -n openshift-monitoring   -o yaml
```

If the ConfigMap is absent, or if its only setting is `enableUserWorkload: false`, apply:

```bash
oc apply   -f platform-monitoring/user-workload-monitoring.yaml
```

If `cluster-monitoring-config` already contains unrelated settings, merge:

```yaml
enableUserWorkload: true
```

into its existing `data.config.yaml` instead of replacing the ConfigMap.

Wait for user-workload Prometheus:

```bash
oc rollout status statefulset/prometheus-user-workload   -n openshift-user-workload-monitoring   --timeout=600s
```

Verify Thanos:

```bash
oc get service thanos-querier   -n openshift-monitoring
```

### 3. Apply Rollouts bootstrap and Prometheus access

```bash
oc apply -k bootstrap

oc apply   -f bootstrap/canary-prometheus-access.yaml
```

Verify that the ServiceAccount token exists:

```bash
oc get secret rollouts-canary-prometheus-token   -n rollouts-canary-demo   -o jsonpath='{.data.token}{"\n"}'
```

The output should be non-empty.

### 4. Apply the Argo CD Application

```bash
oc apply   -f argocd/application-canary.yaml
```

Force a hard refresh:

```bash
oc annotate applications.argoproj.io rollouts-canary-demo   -n openshift-gitops   argocd.argoproj.io/refresh=hard   --overwrite
```

Check synchronization:

```bash
oc get applications.argoproj.io rollouts-canary-demo   -n openshift-gitops   -o jsonpath='sync={.status.sync.status} health={.status.health.status} revision={.status.sync.revision}{"\n"}'
```

Wait for Blackbox Exporter:

```bash
oc rollout status deployment/rollouts-canary-blackbox   -n rollouts-canary-demo   --timeout=300s
```

Verify the analysis resources:

```bash
oc get analysistemplate rollouts-canary-demo-prometheus   -n rollouts-canary-demo

oc get servicemonitor rollouts-canary-blackbox   -n rollouts-canary-demo

oc get service rollouts-canary-demo-canary   -n rollouts-canary-demo
```

### 5. Verify automatic probe traffic

Inspect the ServiceMonitor:

```bash
oc get servicemonitor rollouts-canary-blackbox   -n rollouts-canary-demo   -o yaml
```

Confirm that it points to:

```text
http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

Optionally verify Blackbox directly.

Terminal 1:

```bash
oc port-forward   -n rollouts-canary-demo   svc/rollouts-canary-blackbox   9115:9115
```

Terminal 2:

```bash
curl -sS --get   'http://127.0.0.1:9115/probe'   --data-urlencode 'module=http_200'   --data-urlencode 'target=http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color'   | rg '^(probe_http_status_code|probe_success) '
```

Expected:

```text
probe_http_status_code 200
probe_success 1
```

This manual `curl` is diagnostic only. Prometheus already generates these probes automatically every five seconds.

### 6. Verify the existing public Route

```bash
HOST="$(oc get route rollouts-canary-demo   -n rollouts-canary-demo   -o jsonpath='{.spec.host}')"

echo "https://${HOST}"
```

Check it:

```bash
curl -sk   -o /dev/null   -w 'HTTP %{http_code}\n'   "https://${HOST}/"
```

Expected for a healthy application:

```text
HTTP 200
```

The public Route is not the promotion gate because its normal Service can reach stable and canary pods during rollout.

### 7. Create a fresh GitOps canary revision

Do not patch the live Rollout directly; Argo CD self-heal owns the desired state.

Generate a fresh annotation value:

```bash
TRIGGER="prometheus-$(date -u +%Y%m%dT%H%M%SZ)-$$"

sed -i -E   "s#demo-rollout-revision: ".*"#demo-rollout-revision: "$TRIGGER"#"   canary-demo/rollout.yaml
```

Commit and push:

```bash
git add canary-demo/rollout.yaml
git diff --cached --check
git commit -m "Trigger Prometheus-gated canary revision"
git push origin main
```

Record the exact Git revision:

```bash
REV="$(git rev-parse HEAD)"
echo "$REV"
```

Force Argo CD to refresh:

```bash
oc annotate applications.argoproj.io rollouts-canary-demo   -n openshift-gitops   argocd.argoproj.io/refresh=hard   --overwrite
```

Verify Argo CD reached that exact commit:

```bash
oc get applications.argoproj.io rollouts-canary-demo   -n openshift-gitops   -o jsonpath='sync={.status.sync.status} revision={.status.sync.revision}{"\n"}'
```

The reported revision should equal `$REV`.

### 8. Watch the automatic rollout

Watch the Rollout:

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo   --watch
```

In another terminal, watch AnalysisRuns:

```bash
watch -n 2 '
oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp
'
```

Expected progression:

```text
step 0/7  33%
step 1/7  AnalysisRun
step 2/7  66%
step 3/7  AnalysisRun
step 4/7  100%
step 5/7  AnalysisRun
step 6/7  Paused
```

No operator action is required until step `6/7`.

### 9. Verify canary Service isolation

During the active rollout:

```bash
oc get service rollouts-canary-demo-canary   -n rollouts-canary-demo   -o jsonpath='{.spec.selector}{"\n"}'
```

The selector should include:

```text
rollouts-pod-template-hash
```

Compare it with the ReplicaSets:

```bash
oc get rs   -n rollouts-canary-demo   -l app=rollouts-canary-demo   --show-labels
```

The hash on the canary Service should match the current candidate ReplicaSet, not the old stable ReplicaSet.

### 10. Inspect the successful measurements

List AnalysisRuns:

```bash
oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp
```

Inspect the newest AnalysisRun:

```bash
LATEST_ANALYSIS="$(oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp   -o jsonpath='{.items[-1:].metadata.name}')"

oc get analysisrun "$LATEST_ANALYSIS"   -n rollouts-canary-demo   -o jsonpath='
{range .status.metricResults[*]}
METRIC: {.name}
PHASE: {.phase}
SUCCESS: {.successful}
FAILED: {.failed}
{range .measurements[*]}
  value={.value} phase={.phase} message={.message}
{end}
{end}'
```

A successful gate contains three `200` measurements for `canary-http-status-200` and three `1` measurements for `canary-probe-success`.

### 11. Verify the final pause

At step `6/7`:

```bash
oc get rollout rollouts-canary-demo   -n rollouts-canary-demo   -o jsonpath='phase={.status.phase} step={.status.currentStepIndex} stableRS={.status.stableRS} currentPodHash={.status.currentPodHash}{"\n"}'
```

Expected:

```text
phase=Paused
step=6
```

At this point the candidate has passed the 33%, 66%, and 100% HTTP-200 gates but has not yet been declared stable.

### 12. Promote the validated canary to stable

Display the state first:

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo
```

Promote exactly one step:

```bash
oc argo rollouts promote rollouts-canary-demo   -n rollouts-canary-demo
```

Do not use `--full`.

Wait for the rollout to become healthy:

```bash
oc wait   --for=jsonpath='{.status.phase}'=Healthy   rollout/rollouts-canary-demo   -n rollouts-canary-demo   --timeout=300s
```

Verify stable identity:

```bash
oc get rollout rollouts-canary-demo   -n rollouts-canary-demo   -o jsonpath='phase={.status.phase} stableRS={.status.stableRS} currentPodHash={.status.currentPodHash}{"\n"}'
```

A completed rollout should show:

```text
phase=Healthy
stableRS == currentPodHash
```

Final display:

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo
```

## Quick reference

Scripted execution:

```bash
bash scripts/deploy-canary-demo.sh
bash scripts/prepare-canary-blue.sh
bash scripts/start-canary-yellow.sh
bash scripts/promote-canary-stable.sh
```

Traffic and decision path:

```text
Prometheus --5s scrape--> Blackbox --HTTP GET--> canary-only Service
                                                    |
                                                    v
                                             canary ReplicaSet
                                                    |
                                                    v
                                            HTTP 200 / success
                                                    |
                                                    v
Argo Rollouts <--10s PromQL query-- Thanos/Prometheus
```

The only manual rollout decision is the final promotion at step `6/7`.
