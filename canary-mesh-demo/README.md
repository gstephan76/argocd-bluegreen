# OpenShift GitOps + Argo Rollouts + Service Mesh Canary Demo

This demo is intentionally separate from `canary-demo/`.

The existing canary demo has no traffic router, so its `setWeight` values are
approximated through stable/canary replica counts. This demo uses OpenShift
Service Mesh / Istio as the Argo Rollouts traffic router. Argo Rollouts writes
the `VirtualService` weights directly, so traffic percentages such as 10%, 25%,
50%, and 75% are request-level routing weights rather than pod ratios.

## Architecture

```text
Git -> Argo CD -> Rollout
                    |
           +--------+--------+
           |                 |
      stable Service    canary Service
           |                 |
      stable RS          canary RS
           ^                 ^
           |                 |
           +---- Istio ------+
              VirtualService
                    ^
                    |
              Istio Gateway
                    ^
                    |
             OpenShift Route
```

The rollout sequence is:

```text
10% canary -> Prometheus gate
25% canary -> Prometheus gate
50% canary -> Prometheus gate
75% canary -> Prometheus gate
100% canary -> Prometheus gate
final manual pause
operator promotion -> candidate becomes stable
```

The health gate deliberately probes the canary-only Service directly, so a
healthy stable ReplicaSet cannot hide a broken candidate. The user-facing path
is separate: OpenShift Route -> Istio ingress gateway -> Gateway ->
VirtualService -> weighted stable/canary Services.

## Prerequisites

OpenShift Service Mesh is a prerequisite for this demo; the demo never installs
or reconciles the Service Mesh control plane.

The validated baseline matches the repository `gstephan76/SM` under
`v3/v3.4`:

- OpenShift Service Mesh **3.4 or newer**.
- Sail `Istio/default` Ready in namespace `istio-system`, with
  `spec.namespace: istio-system`.
- Sail `IstioCNI/default` Ready in namespace `istio-cni`.
- The mesh discovery selector accepts namespaces labeled
  `istio-discovery=enabled`.
- OpenShift GitOps with Argo Rollouts and the `oc argo rollouts` CLI plugin.
- OpenShift user-workload monitoring.

The demo namespace is enrolled using the same sidecar-mode contract as the
Service Mesh repository:

```text
istio-discovery=enabled
istio-injection=enabled
```

The demo owns a dedicated Sail-injected ingress gateway and OpenShift Route in
`rollouts-mesh-canary-demo`. Its ingress pod carries
`app.kubernetes.io/component=rollouts-mesh-canary-ingressgateway`, and the
Istio `Gateway` requires that label in addition to `istio=ingressgateway`.
This compound selector prevents wildcard `*:8080` Gateways in other namespaces
from selecting the same ingress workload and avoids Kiali `KIA0301` collisions.

## Demo flow

From the repository root:

```bash
bash scripts/check-canary-mesh-prereqs.sh
bash scripts/deploy-canary-mesh-demo.sh
bash scripts/prepare-canary-mesh-blue.sh
bash scripts/start-canary-mesh-yellow.sh
```

Watch the rollout in another terminal:

```bash
oc argo rollouts get rollout rollouts-mesh-canary-demo \
  -n rollouts-mesh-canary-demo \
  --watch
```

Watch the exact Istio weights:

```bash
watch -n 1 "oc get virtualservice rollouts-mesh-canary \
  -n rollouts-mesh-canary-demo \
  -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%{\"\\n\"}'"
```

Sample the real request distribution through the mesh ingress path:

```bash
REQUESTS=200 bash scripts/sample-canary-mesh-traffic.sh
```

At the final pause, promote the candidate:

```bash
bash scripts/promote-canary-mesh-stable.sh
```

## Why Argo CD ignores selected fields

Argo Rollouts owns these runtime fields:

- `rollouts-pod-template-hash` on the stable Service selector.
- `rollouts-pod-template-hash` on the canary Service selector.
- the `weight` values on the `primary` route in the Istio `VirtualService`.

`argocd/application-canary-mesh.yaml` therefore ignores those fields and uses
`RespectIgnoreDifferences=true`; otherwise Argo CD self-heal could fight the
Rollouts controller during an active rollout.

## Useful inspection commands

```bash
oc get rollout rollouts-mesh-canary-demo \
  -n rollouts-mesh-canary-demo -o yaml

oc get virtualservice rollouts-mesh-canary \
  -n rollouts-mesh-canary-demo -o yaml

oc get service rollouts-mesh-canary-stable \
  rollouts-mesh-canary-canary \
  -n rollouts-mesh-canary-demo -o yaml

oc get analysisrun \
  -n rollouts-mesh-canary-demo \
  --sort-by=.metadata.creationTimestamp
```
