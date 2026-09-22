# OpenShift GitOps + Argo Rollouts Canary Example

This demo uses a fully automatic **Prometheus-gated canary**. There is no manual approval step.

Because this is a basic canary without a traffic router, six replicas are used so the controller can represent approximately one-third and two-thirds as exact pod ratios:

```text
33% -> 2 canary + 4 stable
66% -> 4 canary + 2 stable
100% -> 6 canary
```

## Flow

```text
new canary revision
      |
      v
33% exposure
      |
3 x HTTP 200
      |
      v
66% exposure
      |
3 x HTTP 200
      |
      v
100% exposure
      |
3 x HTTP 200
      |
      v
new ReplicaSet becomes stable
```

A failed analysis stops progression. No timed pause and no manual `promote` is used.

The first canary weight must be established before the first analysis because this demo has no traffic router. In basic canary mode, Argo Rollouts controls the canary replica count to approximate `setWeight`; `setCanaryScale` for an unexposed preflight canary requires traffic routing.

## Exact HTTP 200 gate

The Blackbox Exporter probes only:

```text
http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

The canary-only Service is controlled by Argo Rollouts, so stable pods cannot mask a failing candidate.

The AnalysisTemplate requires three successful Prometheus measurements for both:

```text
probe_http_status_code == 200
probe_success == 1
```

With `failureLimit: 1`, the first failed measurement causes the analysis to fail.

## Deploy

```bash
bash scripts/deploy-canary-demo.sh
```

## Start a fresh rollout

```bash
bash scripts/start-canary-yellow.sh
```

The script changes the Git-managed `demo-rollout-revision` pod-template annotation on every invocation. That creates a fresh Rollout revision even when the image remains `argoproj/rollouts-demo:yellow`.

The script then waits for the automatic 33% -> 66% -> 100% Prometheus-gated rollout to complete.

## Inspect

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo   --watch

oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp
```
