# OpenShift GitOps + Argo Rollouts Canary Example

This example complements the repository's blue/green demo with a **canary Rollout managed by Argo CD and gated by Prometheus AnalysisRuns**.

The canary does not advance merely because a pause expires. At every weight, Argo Rollouts runs an inline AnalysisRun and proceeds only when OpenShift Prometheus reports that a Blackbox probe of the canary-only Service returns HTTP **200**.

## Flow

```text
BLUE stable
   |
Git changes image to YELLOW
   |
Argo CD sync
   |
20% canary
   |
Prometheus AnalysisRun
probe_http_status_code == 200
probe_success == 1
3 consecutive samples
   |
   +-- failure --> Rollout aborts
   |
   +-- success
          |
       manual pause
          |
       promote
          |
40% -> Analysis -> 20s
60% -> Analysis -> 20s
80% -> Analysis -> 20s
          |
       100% YELLOW
```

## Exact HTTP 200 gate

OpenShift HAProxy router metrics group responses into status classes such as `2xx` and therefore cannot distinguish `200` from another `2xx` status. This demo uses Prometheus Blackbox Exporter instead.

The Blackbox module is configured with:

```yaml
valid_status_codes:
  - 200
```

OpenShift user-workload Prometheus scrapes the exporter through a `ServiceMonitor`. The AnalysisTemplate queries OpenShift Thanos for:

```text
probe_http_status_code == 200
probe_success == 1
```

Each inline AnalysisRun requires three consecutive successful measurements. An empty Prometheus result or a non-200 result fails closed.

The Blackbox target is:

```text
http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

`rollouts-canary-demo-canary` is controlled by Argo Rollouts and selects only the current canary ReplicaSet. Stable pods therefore cannot hide a broken canary.

## Prerequisites

OpenShift user-workload monitoring must be enabled:

```bash
oc get statefulset prometheus-user-workload   -n openshift-user-workload-monitoring

oc get service thanos-querier   -n openshift-monitoring
```

## Deploy

```bash
cd ~/Documents/POCs/ArgoCD
bash scripts/deploy-canary-demo.sh
```

Verify:

```bash
oc get analysistemplate,servicemonitor -n rollouts-canary-demo
oc argo rollouts get rollout rollouts-canary-demo -n rollouts-canary-demo
```

## Start BLUE -> YELLOW

```bash
bash scripts/start-canary-yellow.sh
```

The Rollout cannot reach the first manual pause until the 20% Prometheus AnalysisRun succeeds.

## Promote

Only after that analysis succeeds:

```bash
oc argo rollouts promote rollouts-canary-demo   -n rollouts-canary-demo
```

The 40%, 60%, and 80% stages each run their own Prometheus AnalysisRun before continuing.

## Inspect

```bash
oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp

oc get rs,pod   -n rollouts-canary-demo   -l app=rollouts-canary-demo   -o wide
```
