# KEDA-only demo for Red Hat OpenShift 4.20+

This is the presentation path when the goal is to demonstrate **KEDA / Red Hat Custom Metrics Autoscaler only**.

Knative Serving is not required for this demo.

The data path is:

```text
synthetic backlog
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
KEDA Prometheus scaler
      |
      v
generated HPA
      |
      v
keda-async-worker Deployment
```

The worker is intentionally simple. The purpose is to make autoscaling behavior obvious.

The `ScaledObject` uses:

```yaml
minReplicaCount: 0
maxReplicaCount: 5
pollingInterval: 5
cooldownPeriod: 15
```

and a Prometheus threshold of:

```yaml
metricName: demo_async_backlog
threshold: "10"
```

The expected presentation sequence is:

```text
backlog 0  -> 0 workers
backlog 50 -> 5 workers
backlog 5  -> 1 worker
backlog 0  -> 0 workers
```

The Pushgateway is only a deterministic demo signal source. In a real workload, the trigger would normally represent a meaningful external signal such as Kafka lag, queue depth, or an application/business metric.

## Fastest execution

From the repository:

```bash
cd ~/Documents/POCs/ArgoCD/knative
chmod +x scripts/*.sh
```

Run the complete demonstration:

```bash
./scripts/run-keda-demo.sh
```

That one command:

```text
1. verifies OpenShift >= 4.20
2. installs/reconciles Red Hat Custom Metrics Autoscaler
3. waits for the automatically-created KedaController
4. verifies user-workload monitoring
5. deploys Pushgateway, ServiceMonitor, authentication, ScaledObject and worker
6. initializes backlog=0
7. demonstrates 0 -> 5 -> 1 -> 0 workers
8. prints the final KEDA/HPA/Deployment state
```

The script is safe to rerun. If KEDA is already installed, the installation step becomes a quick verification.

To slow the transitions slightly for a presentation:

```bash
DEMO_PAUSE_SECONDS=5 \
./scripts/run-keda-demo.sh
```

## Script-by-script execution

If you want to explain each layer separately:

Install/reconcile KEDA:

```bash
./scripts/install-keda.sh
```

Deploy/reconcile the demo:

```bash
./scripts/deploy-keda.sh
```

Set backlog manually:

```bash
./scripts/set-keda-backlog.sh 0
./scripts/set-keda-backlog.sh 50
./scripts/set-keda-backlog.sh 5
./scripts/set-keda-backlog.sh 0
```

Watch the behavior from another terminal:

```bash
watch -n 2 '
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
'
```

Cleanup only the demo resources:

```bash
./scripts/cleanup-keda.sh
```

Remove the operator too only on a disposable cluster with no other KEDA workloads:

```bash
./scripts/cleanup-keda.sh --platform
```

## Command-by-command execution with `oc`

The following is equivalent to the scripts.

### 1. Verify the cluster version

```bash
oc get clusterversion version \
  -o jsonpath='{.status.desired.version}{"\n"}'
```

The demo requires OpenShift 4.20 or newer.

### 2. Install Red Hat Custom Metrics Autoscaler

```bash
oc apply \
  -f keda/platform/custom-metrics-autoscaler.yaml
```

Watch the Operator:

```bash
oc get subscription,csv \
  -n openshift-keda
```

Wait for the KEDA APIs:

```bash
until oc get crd scaledobjects.keda.sh >/dev/null 2>&1 &&
      oc get crd triggerauthentications.keda.sh >/dev/null 2>&1 &&
      oc get crd kedacontrollers.keda.sh >/dev/null 2>&1
do
  sleep 5
done
```

On supported OpenShift 4.20+ Custom Metrics Autoscaler releases, the Operator creates `KedaController/keda` automatically.

Verify:

```bash
oc get kedacontroller keda \
  -n openshift-keda

oc get deployment \
  keda-operator \
  keda-metrics-apiserver \
  -n openshift-keda
```

### 3. Enable user-workload monitoring

Inspect existing monitoring configuration:

```bash
oc get configmap cluster-monitoring-config \
  -n openshift-monitoring \
  -o yaml
```

If the cluster does not already have custom monitoring configuration:

```bash
oc apply \
  -f ../platform-monitoring/user-workload-monitoring.yaml
```

If `cluster-monitoring-config` contains unrelated settings, merge:

```yaml
enableUserWorkload: true
```

into its existing `data.config.yaml` instead of overwriting it.

Wait for Prometheus:

```bash
oc rollout status \
  statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring \
  --timeout=300s
```

### 4. Deploy the KEDA demo

```bash
oc apply -k keda/app
```

Wait for the metric source:

```bash
oc rollout status \
  deployment/keda-demo-pushgateway \
  -n knative-httpd \
  --timeout=300s
```

Wait for the ScaledObject:

```bash
oc wait \
  --for=condition=Ready \
  scaledobject/keda-async-worker \
  -n knative-httpd \
  --timeout=300s
```

Inspect the generated HPA:

```bash
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
```

### 5. Understand authentication

The `TriggerAuthentication` uses a bound service-account token.

Inspect:

```bash
oc get triggerauthentication keda-thanos \
  -n knative-httpd \
  -o yaml
```

KEDA queries the OpenShift Thanos endpoint:

```text
https://thanos-querier.openshift-monitoring.svc.cluster.local:9092
```

The `keda-thanos` ServiceAccount receives `cluster-monitoring-view`, and the KEDA operator is allowed to request a bound token for that ServiceAccount.

### 6. Publish backlog=50

```bash
oc run keda-backlog-publisher \
  -n knative-httpd \
  --rm -i \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -- \
  sh -c \
  "printf 'demo_async_backlog 50\n' | curl --fail --silent --show-error --data-binary @- http://keda-demo-pushgateway:9091/metrics/job/knative-keda-demo"
```

Watch:

```bash
watch -n 2 '
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
'
```

The worker should converge toward five replicas.

### 7. Publish backlog=5

```bash
oc run keda-backlog-publisher \
  -n knative-httpd \
  --rm -i \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -- \
  sh -c \
  "printf 'demo_async_backlog 5\n' | curl --fail --silent --show-error --data-binary @- http://keda-demo-pushgateway:9091/metrics/job/knative-keda-demo"
```

The worker should converge toward one replica.

### 8. Publish backlog=0

```bash
oc run keda-backlog-publisher \
  -n knative-httpd \
  --rm -i \
  --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -- \
  sh -c \
  "printf 'demo_async_backlog 0\n' | curl --fail --silent --show-error --data-binary @- http://keda-demo-pushgateway:9091/metrics/job/knative-keda-demo"
```

After the configured cooldown, the worker returns to zero replicas.

### 9. Inspect the scaling objects

```bash
oc get scaledobject keda-async-worker \
  -n knative-httpd \
  -o yaml

oc get hpa \
  -n knative-httpd

oc describe scaledobject keda-async-worker \
  -n knative-httpd
```

The core relationship to explain is:

```text
ScaledObject
    |
    | external metric
    v
KEDA
    |
    v
HPA
    |
    v
Deployment replicas
```

### 10. Cleanup

```bash
oc delete -k keda/app
```

The Red Hat Custom Metrics Autoscaler Operator can remain installed for future demos.
