# OpenShift Serverless / Knative Serving + KEDA demo

This directory contains two complementary autoscaling demonstrations:

> **KEDA-only presentation path:** if the goal is to demonstrate only KEDA on
> Red Hat OpenShift 4.20+, use `keda/README.md`. The complete demo is a single
> command:
>
> ```bash
> ./scripts/run-keda-demo.sh
> ```
>
> This path does not require Knative Serving. The remaining Knative files are
> retained as a separate example but are not part of the KEDA presentation.

1. **Knative Serving** for synchronous HTTP request traffic, immutable Revisions, tagged candidate URLs, traffic splitting, scale-to-zero, and cold activation.
2. **Red Hat Custom Metrics Autoscaler (KEDA)** for an asynchronous worker whose replica count is driven by an external Prometheus metric.

They intentionally do **not** control the same Pods.

```text
HTTP request path                           asynchronous/event path

client                                     external backlog metric
  |                                                |
  v                                                v
Knative Service                           OpenShift Prometheus/Thanos
  |                                                |
  v                                                v
KPA                                        KEDA Prometheus scaler
  |                                                |
  v                                                v
Knative Revision                         Kubernetes HPA + Deployment
```

Knative's KPA owns Knative Revision scaling. KEDA owns only the separate `keda-async-worker` Deployment. This avoids two autoscalers fighting over the same replica count.

## What KEDA adds

Knative Serving already scales HTTP workloads very well from request concurrency or RPS. KEDA becomes useful when demand exists **outside the live HTTP request path**, for example:

- Kafka consumer lag;
- Prometheus metrics;
- asynchronous queue or backlog depth;
- batch/event processing;
- scheduled or externally measured demand.

For this demo, KEDA uses the **Prometheus scaler**, which is supported by Red Hat's OpenShift Custom Metrics Autoscaler. A tiny Pushgateway publishes a synthetic `demo_async_backlog` metric. OpenShift user-workload Prometheus scrapes it, Thanos exposes it, and KEDA scales `keda-async-worker` from 0 to 5 replicas.

The synthetic metric is deliberate: it keeps the demo self-contained. In a real system, replace it with an application metric, Kafka lag, or another supported production signal.

## Important support boundary

The base demo does **not** install the upstream experimental Knative `autoscaler-keda` extension and does not attach a KEDA `ScaledObject` to Knative's generated Revision Deployment.

Upstream direct KEDA integrations with Knative Serving/Eventing exist, but the Serving extension is Alpha and KEDA scaling for Knative Kafka resources is documented as Alpha/Technology Preview. The default demo therefore uses the supported OpenShift Custom Metrics Autoscaler beside Knative Serving rather than replacing KPA.

## Layout

```text
knative/
├── README.md
├── app/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── configmap-v2.yaml
│   ├── service.yaml
│   └── kustomization.yaml
├── platform/
│   ├── serverless-subscription.yaml
│   └── knative-serving.yaml
├── keda/
│   ├── platform/
│   │   ├── custom-metrics-autoscaler.yaml
│   │   └── keda-controller.yaml
│   └── app/
│       ├── pushgateway.yaml
│       ├── worker.yaml
│       ├── auth.yaml
│       ├── scaledobject.yaml
│       └── kustomization.yaml
└── scripts/
    ├── install-serverless.sh
    ├── deploy.sh
    ├── verify.sh
    ├── new-revision.sh
    ├── split-traffic.sh
    ├── promote-v2.sh
    ├── install-keda.sh
    ├── deploy-keda.sh
    ├── set-keda-backlog.sh
    ├── run-keda-demo.sh
    ├── cleanup-keda.sh
    └── cleanup.sh
```

# Scripted execution

## Live session: scripts and terminals

The Knative directory contains two separate demonstrations. Run the Knative
Serving session and the KEDA session independently during a presentation.

### Knative Serving session

**Terminal 1 — operator/control**

Run these scripts sequentially:

```bash
cd ~/Documents/POCs/ArgoCD/knative

./scripts/install-serverless.sh
./scripts/deploy.sh
./scripts/verify.sh

# Scale-to-zero and cold activation.
./scripts/verify.sh --scale-to-zero

# Revision and traffic-management demonstration.
./scripts/new-revision.sh
./scripts/split-traffic.sh 50
./scripts/promote-v2.sh
```

Wait for each command to finish before running the next one. While
`verify.sh --scale-to-zero` is waiting for zero Pods, do not refresh the
application URL because that traffic keeps the Revision active.

**Terminal 2 — Knative resources**

```bash
watch -n 2 '
oc get ksvc,configuration,revision,pod \
  -n knative-httpd
'
```

**Terminal 3 — Knative routing**

Optional when explaining Revision traffic:

```bash
watch -n 2 '
oc get ksvc,route \
  -n knative-httpd
'
```

### KEDA session

Present KEDA as two explicit phases.

**Terminal 1 — Phase 1: declarative deployment**

```bash
cd ~/Documents/POCs/ArgoCD/knative

# Show the declarative autoscaling policy.
bat keda/app/scaledobject.yaml

./scripts/01-deploy-keda-demo.sh
```

The Step 1 helper installs/reconciles the Red Hat Custom Metrics Autoscaler,
reuses the OpenShift user-workload Prometheus/Thanos stack already used by the
Canary demo, applies the existing KEDA manifests, and establishes the
zero-backlog / zero-worker baseline.

**Terminal 2 — KEDA/HPA/workload watch**

Start this before Step 2 and leave it running:

```bash
watch -n 2 '
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
'
```

**Terminal 3 — Prometheus/KEDA objects**

Optional for explaining the metrics path:

```bash
watch -n 2 '
oc get servicemonitor,triggerauthentication \
  -n knative-httpd
'
```

**Terminal 1 — Phase 2: scale out and scale in**

```bash
./scripts/02-scale-keda-demo.sh
```

The expected sequence is:

```text
backlog 0  -> workers 0
backlog 50 -> workers 5
backlog 5  -> workers 1
backlog 0  -> workers 0
```

The intended KEDA session is:

```text
Terminal 1                         Terminal 2                  Terminal 3
----------                         ----------                  ----------
show scaledobject.yaml             KEDA/HPA/workers            metrics objects
01-deploy-keda-demo.sh             baseline workers=0
02-scale-keda-demo.sh              0 -> 5 -> 1 -> 0            Prometheus path
```

Run from the Knative directory:

```bash
cd ~/Documents/POCs/ArgoCD/knative
chmod +x scripts/*.sh
```

## A. Knative Serving demo

Install Serverless if needed:

```bash
./scripts/install-serverless.sh
```

Deploy/reset V1:

```bash
./scripts/deploy.sh
```

Verify normal HTTP service:

```bash
./scripts/verify.sh
```

Demonstrate scale-to-zero and cold activation:

```bash
./scripts/verify.sh --scale-to-zero
```

Create V2 while leaving the main URL on V1:

```bash
./scripts/new-revision.sh
```

Apply a native Knative 50/50 split:

```bash
./scripts/split-traffic.sh 50
```

Promote V2 to 100%:

```bash
./scripts/promote-v2.sh
```

## B. KEDA companion demo

Install Red Hat Custom Metrics Autoscaler if needed:

```bash
./scripts/install-keda.sh
```

Deploy the Prometheus signal source, authentication, ScaledObject, and worker:

```bash
./scripts/deploy-keda.sh
```

Run the complete KEDA scaling sequence:

```bash
./scripts/run-keda-demo.sh
```

Expected behavior:

```text
demo_async_backlog = 0
    -> worker replicas = 0

demo_async_backlog = 50
    -> worker replicas = 5

demo_async_backlog = 5
    -> worker replicas = 1

demo_async_backlog = 0
    -> worker replicas = 0
```

The KEDA target is 10 backlog units per worker with `maxReplicaCount: 5`.

You can drive individual values manually:

```bash
./scripts/set-keda-backlog.sh 20
./scripts/set-keda-backlog.sh 40
./scripts/set-keda-backlog.sh 0
```

# Command-by-command execution

The sections below perform the same demo without helper scripts.

## 1. Verify access

```bash
oc whoami
```

Check Serverless APIs:

```bash
oc get crd services.serving.knative.dev
oc get crd knativeservings.operator.knative.dev
```

Check KEDA APIs when installed:

```bash
oc get crd scaledobjects.keda.sh
oc get crd kedacontrollers.keda.sh
```

## 2. Install OpenShift Serverless manually

```bash
oc apply \
  -f platform/serverless-subscription.yaml

oc get subscription,csv \
  -n openshift-serverless
```

Wait for the Operator CRD:

```bash
until oc get crd knativeservings.operator.knative.dev >/dev/null 2>&1; do
  sleep 5
done
```

Create Knative Serving:

```bash
oc apply \
  -f platform/knative-serving.yaml

oc wait \
  --for=condition=Ready \
  knativeserving/knative-serving \
  -n knative-serving \
  --timeout=600s
```

Inspect:

```bash
oc get knativeserving knative-serving \
  -n knative-serving

oc get pods \
  -n knative-serving
```

## 3. Deploy V1 manually

```bash
oc apply -k app
```

Reset traffic to latest/V1:

```bash
oc patch ksvc httpd-single-page \
  -n knative-httpd \
  --type=merge \
  -p '{"spec":{"traffic":[{"latestRevision":true,"percent":100}]}}'
```

Wait:

```bash
oc wait \
  --for=condition=Ready \
  ksvc/httpd-single-page \
  -n knative-httpd \
  --timeout=300s
```

Inspect the Serving object hierarchy:

```bash
oc get ksvc,configuration,revision,route,pod \
  -n knative-httpd
```

Get the URL:

```bash
URL="$(oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{.status.url}')"

echo "$URL"
curl "$URL"
```

## 4. Observe scale-to-zero manually

Generate one request:

```bash
curl "$URL" >/dev/null
```

Watch the application Pods:

```bash
watch -n 2 \
  'oc get pod -n knative-httpd'
```

Stop generating traffic. After Knative's stable window, the Revision can reach zero running Pods.

Then send a new request:

```bash
curl "$URL" >/dev/null
```

Watch a Revision Pod appear again:

```bash
oc get pod \
  -n knative-httpd \
  -w
```

## 5. Create V2 manually

Capture V1:

```bash
CURRENT="$(oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{.status.latestReadyRevisionName}')"
```

Pin it at 100% and create a 0% candidate tag:

```bash
oc patch ksvc httpd-single-page \
  -n knative-httpd \
  --type=merge \
  -p "{
    \"spec\": {
      \"traffic\": [
        {
          \"revisionName\": \"${CURRENT}\",
          \"percent\": 100,
          \"tag\": \"current\"
        },
        {
          \"latestRevision\": true,
          \"percent\": 0,
          \"tag\": \"candidate\"
        }
      ]
    }
  }"
```

Create V2 by changing the Revision template to the immutable V2 ConfigMap:

```bash
TRIGGER="v2-$(date -u +%Y%m%dT%H%M%SZ)"

oc patch ksvc httpd-single-page \
  -n knative-httpd \
  --type=merge \
  -p "{
    \"spec\": {
      \"template\": {
        \"metadata\": {
          \"annotations\": {
            \"demo.knative.dev/version\": \"${TRIGGER}\"
          }
        },
        \"spec\": {
          \"volumes\": [
            {
              \"name\": \"page\",
              \"configMap\": {
                \"name\": \"httpd-page-v2\",
                \"items\": [
                  {
                    \"key\": \"index.html\",
                    \"path\": \"index.html\"
                  }
                ]
              }
            }
          ]
        }
      }
    }
  }"
```

Wait and inspect:

```bash
oc wait \
  --for=condition=Ready \
  ksvc/httpd-single-page \
  -n knative-httpd \
  --timeout=300s

oc get revision \
  -n knative-httpd
```

Get candidate URL:

```bash
CANDIDATE_URL="$(oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{.status.traffic[?(@.tag=="candidate")].url}')"

curl "$CANDIDATE_URL"
```

## 6. Split and promote Knative traffic manually

Capture V2:

```bash
CANDIDATE="$(oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{.status.latestReadyRevisionName}')"
```

50/50:

```bash
oc patch ksvc httpd-single-page \
  -n knative-httpd \
  --type=merge \
  -p "{
    \"spec\": {
      \"traffic\": [
        {
          \"revisionName\": \"${CURRENT}\",
          \"percent\": 50,
          \"tag\": \"current\"
        },
        {
          \"revisionName\": \"${CANDIDATE}\",
          \"percent\": 50,
          \"tag\": \"candidate\"
        }
      ]
    }
  }"
```

Inspect:

```bash
oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{range .status.traffic[*]}{.percent}{"% -> "}{.revisionName}{" tag="}{.tag}{"\n"}{end}'
```

Promote V2:

```bash
oc patch ksvc httpd-single-page \
  -n knative-httpd \
  --type=merge \
  -p "{
    \"spec\": {
      \"traffic\": [
        {
          \"revisionName\": \"${CANDIDATE}\",
          \"percent\": 100
        }
      ]
    }
  }"
```

## 7. Install Red Hat Custom Metrics Autoscaler manually

Install the Operator:

```bash
oc apply \
  -f keda/platform/custom-metrics-autoscaler.yaml
```

Wait for KEDA CRDs:

```bash
until oc get crd scaledobjects.keda.sh >/dev/null 2>&1; do
  sleep 5
done
```

OpenShift 4.22 normally creates the `KedaController` automatically. Verify:

```bash
oc get kedacontroller \
  -n openshift-keda
```

If no `keda` controller exists:

```bash
oc apply \
  -f keda/platform/keda-controller.yaml
```

Verify KEDA components:

```bash
oc get deployment,pod \
  -n openshift-keda
```

You should see the operator plus:

```text
keda-operator
keda-metrics-apiserver
keda-admission
```

## 8. Enable user-workload monitoring

Inspect the existing configuration first:

```bash
oc get configmap cluster-monitoring-config \
  -n openshift-monitoring \
  -o yaml
```

If no custom configuration exists, apply the repository setting:

```bash
oc apply \
  -f ../platform-monitoring/user-workload-monitoring.yaml
```

If `cluster-monitoring-config` already contains unrelated settings, merge:

```yaml
enableUserWorkload: true
```

into its existing `data.config.yaml` rather than replacing the ConfigMap.

Wait:

```bash
oc rollout status \
  statefulset/prometheus-user-workload \
  -n openshift-user-workload-monitoring \
  --timeout=300s
```

## 9. Deploy KEDA demo resources manually

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

Inspect:

```bash
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
```

The worker should start at zero replicas.

## 10. Publish backlog values manually

Publish a backlog of 50:

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

Watch KEDA/HPA:

```bash
watch -n 2 '
oc get scaledobject,hpa,deployment,pod \
  -n knative-httpd
'
```

With a target of 10 and max 5, the demo should converge toward five worker replicas.

Publish 5:

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

Publish zero:

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

After the KEDA cooldown, the worker scales to zero.

## 11. Understand the KEDA data path

The KEDA demo path is:

```text
set-keda-backlog.sh
        |
        | pushes demo_async_backlog
        v
Prometheus Pushgateway
        |
        | ServiceMonitor every 5s
        v
OpenShift user-workload Prometheus
        |
        v
Thanos Querier :9092
        |
        | PromQL from ScaledObject
        v
KEDA operator
        |
        v
generated HPA
        |
        v
keda-async-worker Deployment
```

The `ScaledObject` query is:

```promql
max(demo_async_backlog{demo="knative-keda"}) or on() vector(0)
```

and uses:

```yaml
threshold: "10"
activationThreshold: "0"
minReplicaCount: 0
maxReplicaCount: 5
```

KEDA handles activation/deactivation between zero and one replica. Above one replica, the generated HPA performs normal 1-to-N scaling from the KEDA external metric.

## 12. Cleanup

Application-only Knative cleanup:

```bash
./scripts/cleanup.sh
```

KEDA companion resources only:

```bash
./scripts/cleanup-keda.sh
```

Remove KEDA platform as well:

```bash
./scripts/cleanup-keda.sh --platform
```

Do not use `--platform` on a cluster with other KEDA workloads.

Remove Serverless platform too:

```bash
./scripts/cleanup.sh --platform
```

Do not remove shared platform Operators from a cluster used by other workloads.
