# Whole-application Bookinfo canary with OpenShift Service Mesh

`canary-mesh-bookinfo` is a separate demo from `canary-mesh-demo`.

The original mesh demo progressively routes traffic between two revisions of one
small workload. This demo treats **the complete Bookinfo request path** as the
canary unit:

```text
OpenShift Route
      |
      v
Istio ingress gateway
      |
      v
Argo Rollouts / Istio VirtualService
      |
      +---- stable -------------------------------+
      |                                           |
      v                                           v
productpage stable                         productpage canary
      |                                           |
      +--> details-stable                         +--> details-canary
      +--> reviews-stable                         +--> reviews-canary
              |                                           |
              +--> ratings-stable                         +--> ratings-canary
```

A request is never intentionally mixed across tracks. Stable productpage points
only at stable downstream Services; candidate productpage points only at canary
downstream Services.

## What is actually canaried

All four Bookinfo services participate:

| Service | Stable track | Canary track |
|---|---|---|
| productpage | stable ReplicaSet selected by Argo Rollouts | candidate ReplicaSet selected by Argo Rollouts |
| details | `bookinfo-details-stable` | `bookinfo-details-canary` |
| reviews | v2 / black stars | v3 / red stars |
| ratings | `bookinfo-ratings-stable` | `bookinfo-ratings-canary` |

`details` and `ratings` intentionally use the same container version on both
tracks so the demo shows that a whole-application revision can include components
whose binary did not change. They are still separate canary pods and Services and
are exercised by the canary request path.

Argo Rollouts owns the **front-door traffic percentage** through productpage.
The downstream stable/canary workloads are declared in parallel by Argo CD. This
keeps one application revision cohesive instead of running four independent
traffic percentages that could mix service revisions.

The candidate health gate probes the canary-only productpage Service and requires:

- HTTP 200;
- `Book Details`;
- `Book Reviews`;
- rendered review stars from reviews v3;
- Istio request metrics proving traffic reached the canary details, reviews, and
  ratings workloads.

## Canary sequence

```text
90% stable / 10% whole-app canary -> analysis
75% stable / 25% whole-app canary -> analysis
50% stable / 50% whole-app canary -> analysis
25% stable / 75% whole-app canary -> analysis
0% stable / 100% whole-app canary -> analysis
manual approval
```

## Prerequisites

The demo does **not** install or reconcile OpenShift Service Mesh. It expects the
same OSSM 3.4+ sidecar-mode prerequisite as `canary-mesh-demo` and reuses
`scripts/check-canary-mesh-prereqs.sh`.

Required platform components:

- OpenShift Service Mesh 3.4 or newer;
- Sail `Istio/default` and `IstioCNI/default` Ready;
- `istio-discovery=enabled` accepted by the mesh discovery selector;
- OpenShift GitOps with Argo Rollouts;
- `oc argo rollouts` CLI;
- OpenShift user-workload monitoring.

The namespace is:

```text
canary-mesh-bookinfo
```

and the dedicated ingress gateway uses the isolated compound selector:

```text
istio=ingressgateway
app.kubernetes.io/component=canary-mesh-bookinfo-ingressgateway
```

## Demo workflow

From the repository root:

```bash
bash scripts/deploy-canary-mesh-bookinfo.sh
bash scripts/prepare-canary-mesh-bookinfo.sh
bash scripts/start-canary-mesh-bookinfo.sh
```

Watch rollout state:

```bash
oc argo rollouts get rollout canary-mesh-bookinfo   -n canary-mesh-bookinfo   --watch
```

Watch exact Istio weights:

```bash
watch -n 1 "oc get virtualservice canary-mesh-bookinfo   -n canary-mesh-bookinfo   -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%{"\n"}'"
```

Sample the real whole-application distribution:

```bash
REQUESTS=200 bash scripts/sample-canary-mesh-bookinfo.sh
```

Stable requests are identified by the reviews-v2 black-star response; candidate
requests are identified by the reviews-v3 red-star response.

At the final 100% pause:

```bash
bash scripts/promote-canary-mesh-bookinfo.sh
```

Before starting another run, restore the stable baseline:

```bash
bash scripts/prepare-canary-mesh-bookinfo.sh
```

## Useful checks

```bash
bash scripts/check-canary-mesh-bookinfo-dataplane.sh

oc get rollout canary-mesh-bookinfo   -n canary-mesh-bookinfo -o yaml

oc get virtualservice canary-mesh-bookinfo   -n canary-mesh-bookinfo -o yaml

oc get pods -n canary-mesh-bookinfo   -L app,track,version

oc get analysisrun -n canary-mesh-bookinfo   --sort-by=.metadata.creationTimestamp
```
