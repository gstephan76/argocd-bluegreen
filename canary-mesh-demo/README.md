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

- OpenShift GitOps with Argo Rollouts and the `oc argo rollouts` CLI plugin.
- OpenShift Service Mesh 3 with the Istio `Gateway` and `VirtualService` CRDs.
- An Istio ingress gateway Service reachable by an OpenShift Route.
- OpenShift user-workload monitoring.
- A namespace injection revision/tag. The scripts default to `default`; set
  `ISTIO_REVISION` when the cluster uses another revision or revision tag.

If more than one ingress gateway exists, set both:

```bash
export MESH_INGRESS_NAMESPACE=<gateway-namespace>
export MESH_INGRESS_SERVICE=<gateway-service>
```

## Demo flow

From the repository root:

```bash
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
