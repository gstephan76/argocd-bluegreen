# Two-step KEDA presentation — OpenShift 4.20+

This is the shortest presentation path for the repository's existing KEDA demo.

It does **not** replace the existing KEDA manifests or helper scripts. It simply
organizes them into two presentation phases:

```text
STEP 1
Declarative deployment

STEP 2
Scale out / scale in / scale to zero
```

The KEDA demo reuses the same OpenShift user-workload Prometheus/Thanos stack
already used by the Canary demo. No second Prometheus instance is deployed.

## Architecture

```text
demo_async_backlog
        |
        v
Prometheus Pushgateway
        |
        | ServiceMonitor
        v
OpenShift user-workload Prometheus
        |
        v
Thanos Querier
        |
        | PromQL
        v
KEDA ScaledObject
        |
        v
generated HPA
        |
        v
keda-async-worker Deployment
```

The Canary and KEDA demos therefore share:

```text
platform-monitoring/user-workload-monitoring.yaml
OpenShift user-workload Prometheus
OpenShift Thanos Querier
```

The Canary AnalysisRun and KEDA use different API paths/ports into Thanos, but
the monitoring backend is the same OpenShift monitoring stack.

# Step 1 — declarative deployment

From the repository:

```bash
cd ~/Documents/POCs/ArgoCD/knative
```

First show how small the autoscaling policy is:

```bash
bat keda/app/scaledobject.yaml
```

The essential policy is:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: keda-async-worker
  namespace: knative-httpd
spec:
  scaleTargetRef:
    name: keda-async-worker

  pollingInterval: 5
  cooldownPeriod: 15

  minReplicaCount: 0
  maxReplicaCount: 5

  triggers:
    - type: prometheus
      metadata:
        serverAddress: https://thanos-querier.openshift-monitoring.svc.cluster.local:9092
        namespace: knative-httpd
        metricName: demo_async_backlog
        query: max(demo_async_backlog{demo="knative-keda"}) or on() vector(0)
        threshold: "10"
        activationThreshold: "0"
        authModes: bearer
      authenticationRef:
        name: keda-thanos
        kind: TriggerAuthentication
```

Run the deployment phase:

```bash
./scripts/01-deploy-keda-demo.sh
```

Internally, the application is still deployed declaratively with:

```bash
oc apply -k keda/app
```

The step also performs the platform preflight automatically:

```text
OpenShift >= 4.20
Red Hat Custom Metrics Autoscaler installed/reconciled
KedaController ready
user-workload Prometheus already available or safely enabled
Thanos path available through the existing OpenShift monitoring stack
```

At the end of Step 1:

```text
demo_async_backlog = 0
worker replicas    = 0
```

Inspect:

```bash
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
```

## Command-by-command Step 1

Verify the OpenShift version:

```bash
oc get clusterversion version \
  -o jsonpath='{.status.desired.version}{"\n"}'
```

Install/reconcile Red Hat Custom Metrics Autoscaler:

```bash
./scripts/install-keda.sh
```

Verify the same monitoring stack used by the Canary demo:

```bash
oc get statefulset prometheus-user-workload \
  -n openshift-user-workload-monitoring

oc get service thanos-querier \
  -n openshift-monitoring
```

Show the declarative KEDA resources:

```bash
bat keda/app/worker.yaml
bat keda/app/auth.yaml
bat keda/app/scaledobject.yaml
bat keda/app/pushgateway.yaml
```

Apply them:

```bash
oc apply -k keda/app
```

Wait:

```bash
oc rollout status \
  deployment/keda-demo-pushgateway \
  -n knative-httpd \
  --timeout=300s

oc wait \
  --for=condition=Ready \
  scaledobject/keda-async-worker \
  -n knative-httpd \
  --timeout=300s
```

Initialize the metric:

```bash
./scripts/set-keda-backlog.sh 0
```

Inspect:

```bash
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
```

# Step 2 — scale out and scale in

Run:

```bash
./scripts/02-scale-keda-demo.sh
```

The presentation sequence is:

```text
backlog 0
workers 0

   SCALE OUT

backlog 50
workers 5

   SCALE IN

backlog 5
workers 1

   SCALE TO ZERO

backlog 0
workers 0
```

The threshold is:

```text
10 backlog units per worker
```

and the maximum is:

```text
5 workers
```

Use a second terminal during Step 2:

```bash
watch -n 2 '
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
'
```

This makes the KEDA control chain visible:

```text
Prometheus metric
       |
       v
ScaledObject
       |
       v
KEDA
       |
       v
generated HPA
       |
       v
Deployment replicas
```

## Command-by-command Step 2

Baseline:

```bash
./scripts/set-keda-backlog.sh 0
```

Scale out:

```bash
./scripts/set-keda-backlog.sh 50
```

Expected:

```text
5 workers
```

Scale in:

```bash
./scripts/set-keda-backlog.sh 5
```

Expected:

```text
1 worker
```

Scale to zero:

```bash
./scripts/set-keda-backlog.sh 0
```

Expected after cooldown:

```text
0 workers
```

# Cleanup

Remove only the demo resources:

```bash
./scripts/cleanup-keda.sh
```

Leave the Red Hat Custom Metrics Autoscaler installed for later demos.

Only on a disposable cluster with no other KEDA workloads:

```bash
./scripts/cleanup-keda.sh --platform
```
