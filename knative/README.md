# Knative HTTPD single-page demo

This directory is an independent OpenShift Serverless / Knative Serving example. It does not change the existing Argo CD blue-green demo in this repository.

The demo deploys a static single-page application with the Red Hat UBI 9 Apache HTTP Server image (`registry.access.redhat.com/ubi9/httpd-24`) as a Knative `Service`. The application listens on port `8080`, uses the Knative Pod Autoscaler, and is explicitly configured with `min-scale: 0` so it can scale to zero when idle.

## Layout

```text
knative/
├── README.md
├── app/
│   ├── configmap.yaml
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   └── service.yaml
├── platform/
│   ├── knative-serving.yaml
│   └── serverless-subscription.yaml
└── scripts/
    ├── cleanup.sh
    ├── deploy.sh
    ├── install-serverless.sh
    └── verify.sh
```

## Prerequisites

- OpenShift Container Platform with the Red Hat Operator catalog available.
- `oc` installed and logged in.
- Cluster-admin privileges are required only when installing the OpenShift Serverless Operator and Knative Serving.
- Application deployment requires permissions to create resources in the `knative-httpd` namespace.
- `curl` is required by the verification script.

## 1. Install OpenShift Serverless and Knative Serving

Skip this step if Knative Serving is already installed and `services.serving.knative.dev` is available on the cluster.

```bash
cd knative
chmod +x scripts/*.sh
./scripts/install-serverless.sh
```

The platform installation is intentionally split into two manifests:

1. `platform/serverless-subscription.yaml` installs the OpenShift Serverless Operator from the `redhat-operators` catalog using the `stable` channel.
2. `platform/knative-serving.yaml` creates the `KnativeServing` instance in `knative-serving` and explicitly enables scale-to-zero.

Verify the platform manually with:

```bash
oc get subscription -n openshift-serverless
oc get csv -n openshift-serverless
oc get knativeserving knative-serving -n knative-serving
oc get pods -n knative-serving
oc get crd services.serving.knative.dev
```

## 2. Deploy the HTTPD Knative Service

```bash
cd knative
./scripts/deploy.sh
```

The script applies `app/` with Kustomize, waits for the Knative Service to become `Ready`, and prints its externally reachable URL.

Equivalent manual deployment:

```bash
oc apply -k app
oc wait --for=condition=Ready \
  ksvc/httpd-single-page \
  -n knative-httpd \
  --timeout=300s

oc get ksvc httpd-single-page -n knative-httpd
```

Get the URL:

```bash
URL="$(oc get ksvc httpd-single-page \
  -n knative-httpd \
  -o jsonpath='{.status.url}')"

echo "$URL"
curl "$URL"
```

If your lab uses an untrusted ingress certificate, set `CURL_INSECURE=1` when running the verification script instead of editing it to hard-code `curl -k`.

## 3. Verify the application

Basic readiness and HTTP response test:

```bash
./scripts/verify.sh
```

The script checks the `ksvc`, lists its revisions, requests the Knative URL, and verifies that the returned page contains the expected content.

## 4. Demonstrate scale-to-zero

Run:

```bash
./scripts/verify.sh --scale-to-zero
```

The test performs three stages:

```text
HTTP request
    │
    ▼
HTTPD revision pod running
    │
    │ no traffic
    ▼
Knative Pod Autoscaler
    │
    ▼
0 revision pods
    │
    │ new HTTP request
    ▼
Knative activation path
    │
    ▼
HTTPD revision pod running again
```

The default wait for scale-to-zero is 180 seconds. Override it when necessary:

```bash
ZERO_TIMEOUT=300 ./scripts/verify.sh --scale-to-zero
```

Useful commands while watching the transition:

```bash
watch oc get pods -n knative-httpd
```

In another terminal:

```bash
oc get ksvc,configuration,revision,route -n knative-httpd
```

## Autoscaling settings

`app/service.yaml` uses these revision annotations:

```yaml
autoscaling.knative.dev/min-scale: "0"
autoscaling.knative.dev/max-scale: "5"
autoscaling.knative.dev/metric: concurrency
autoscaling.knative.dev/target: "20"
```

`containerConcurrency: 50` places a hard concurrency limit on each revision pod, while the autoscaler target asks Knative to scale around 20 concurrent requests per pod.

## Update the page

Edit `app/configmap.yaml` and re-run:

```bash
./scripts/deploy.sh
```

The page is mounted from the ConfigMap at `/var/www/html/index.html`. Because the file is mounted with `subPath`, an already-running pod does not live-update the mounted file. For a deterministic content rollout, delete the current revision pod after updating the ConfigMap or change the Knative Service template to create a new revision. A pod created after scale-to-zero will consume the current ConfigMap content.

## Cleanup

Remove only the demo application:

```bash
./scripts/cleanup.sh
```

Remove the demo and the Serverless platform resources installed by this directory:

```bash
./scripts/cleanup.sh --platform
```

Do not use `--platform` on a cluster where other applications depend on Knative Serving.
