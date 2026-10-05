# Multi-Bookinfo canary with OpenShift Service Mesh

`canary-mesh-multi-bookinfo` demonstrates two complete Bookinfo applications in
the **same namespace**, each with a distinct external OpenShift Route.

The independence boundary is the complete application:

- **Bookinfo A** is one static application.
- **Bookinfo B** is one independently deployable application and is the only
  application managed by Argo Rollouts for progressive delivery.

The services inside a Bookinfo application are not independent rollout units.

The GitOps boundary follows the same model:

- `canary-mesh-multi-bookinfo-a` manages the complete static Bookinfo A.
- `canary-mesh-multi-bookinfo-b` manages the complete Bookinfo B progressive-delivery stack.
- `canary-mesh-multi-bookinfo-shared` owns only shared namespace/ingress/monitoring infrastructure.

The shared Argo CD Application is infrastructure, not a third Bookinfo application.

## Architecture

```text
                     namespace: canary-mesh-multi-bookinfo

                         shared Istio ingress
                                  |
                 +----------------+----------------+
                 |                                 |
          external Route A                  external Route B
                 |                                 |
         VirtualService A                  VirtualService B
                 |                                 |
          BOOKINFO A STATIC                BOOKINFO B ROLLOUT
                 |                          /              \
                 |                     stable              canary
                 |                       |                   |
       productpage-a              productpage-b       productpage-b
        /          \                 /      \             /      \
   details-a     reviews-a      details   reviews      details   reviews
                    |                       |                       |
                ratings-a               ratings                 ratings
```

Both routes target the same dedicated Istio ingress gateway Service. The two
VirtualServices remain disjoint by matching the OpenShift-generated route
authority:

```text
bookinfo-a-canary-mesh-multi-bookinfo.<apps-domain>
bookinfo-b-canary-mesh-multi-bookinfo.<apps-domain>
```

## Isolation model

Every workload and Service carries an application-instance identity:

```text
app.kubernetes.io/instance=bookinfo-a
```

or:

```text
app.kubernetes.io/instance=bookinfo-b
```

Bookinfo B additionally uses `track=stable|canary` for its downstream stacks.

This prevents a Service in one Bookinfo application from selecting pods from the
other application even though both applications share the same namespace.

## Bookinfo A

Bookinfo A is a conventional Argo CD-managed application:

```text
bookinfo-a-productpage
  -> bookinfo-a-details
  -> bookinfo-a-reviews (v2 / black stars)
       -> bookinfo-a-ratings
```

Its route and traffic do not change during the Bookinfo B rollout.

## Bookinfo B

Bookinfo B uses one front-door Argo Rollout. Argo Rollouts owns the
stable/canary productpage ReplicaSets and the traffic weights in
`VirtualService/bookinfo-b`.

The productpage revision determines the entire downstream application track:

```text
Bookinfo B stable:
productpage
  -> bookinfo-b-details-stable
  -> bookinfo-b-reviews-stable (v2 / black stars)
       -> bookinfo-b-ratings-stable

Bookinfo B canary:
productpage
  -> bookinfo-b-details-canary
  -> bookinfo-b-reviews-canary (v3 / red stars)
       -> bookinfo-b-ratings-canary
```

There are deliberately **not** four independent Rollout CRs. Traffic is split
once at the Bookinfo B application boundary, so a request is never intentionally
mixed between stable and canary downstream tracks.

## Canary sequence

Bookinfo B progresses through:

```text
90% stable / 10% canary -> analysis
75% stable / 25% canary -> analysis
50% stable / 50% canary -> analysis
25% stable / 75% canary -> analysis
0% stable / 100% canary -> analysis
manual approval
```

The candidate analysis probes Bookinfo B's canary-only productpage Service and
requires HTTP success, Bookinfo page content, reviews-v3 red stars, and Istio
metrics proving that `details-canary`, `reviews-canary`, and `ratings-canary`
were reached.

Bookinfo A is not part of those traffic weights.

## Prerequisites

The demo does **not** install or reconcile OpenShift Service Mesh.

It requires the same prerequisites as `canary-mesh-bookinfo`:

- OpenShift Service Mesh 3.4 or newer;
- Sail `Istio/default` and `IstioCNI/default` Ready;
- the mesh discovery selector accepts `istio-discovery=enabled`;
- OpenShift GitOps with Argo Rollouts;
- `oc argo rollouts`;
- OpenShift user-workload monitoring.

## Demo workflow

From the repository root:

```bash
bash scripts/deploy-canary-mesh-multi-bookinfo.sh
bash scripts/prepare-canary-mesh-multi-bookinfo.sh
bash scripts/start-canary-mesh-multi-bookinfo.sh
```

Observe Bookinfo B:

```bash
oc argo rollouts get rollout bookinfo-b \
  -n canary-mesh-multi-bookinfo \
  --watch
```

Sample both external routes:

```bash
REQUESTS_A=20 REQUESTS_B=200 \
bash scripts/sample-canary-mesh-multi-bookinfo.sh
```

Expected behavior:

- Bookinfo A remains 100% static / black-star reviews.
- Bookinfo B follows the current stable/canary weight.

At Bookinfo B's final 100% candidate pause:

```bash
bash scripts/promote-canary-mesh-multi-bookinfo.sh
```

Reset Bookinfo B for another demo while keeping Bookinfo A untouched:

```bash
bash scripts/prepare-canary-mesh-multi-bookinfo.sh
```

## Idempotency

The operational scripts follow the same idempotency contract as
`canary-mesh-bookinfo`.

`deploy` may be rerun without forcing Bookinfo B to baseline.

`prepare` may be rerun at baseline, during the rollout, at the final pause, or
after promotion. It restores Bookinfo B to:

```text
phase == Healthy
stableRS == currentPodHash
marker == bookinfo-b-baseline-stable
Bookinfo B stable routing == 100%
Bookinfo B canary routing == 0%
```

and also verifies that Bookinfo A remained healthy.

`start` reuses an already-declared Bookinfo B candidate instead of creating
another timestamped candidate.

`promote` treats an already-promoted Bookinfo B candidate as a verified no-op.

The scripts never silently commit unrelated tracked Git changes.

## External URLs

Retrieve both hosts with:

```bash
oc get route bookinfo-a bookinfo-b \
  -n canary-mesh-multi-bookinfo
```

The application pages are:

```text
https://<bookinfo-a-host>/productpage
https://<bookinfo-b-host>/productpage
```

The current VirtualServices intentionally expose `/productpage` and the
supporting Bookinfo paths rather than bare `/`.

## Useful checks

```bash
bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh

oc get pods -n canary-mesh-multi-bookinfo \
  -L app.kubernetes.io/instance,app.kubernetes.io/name,track

oc get route bookinfo-a bookinfo-b \
  -n canary-mesh-multi-bookinfo

oc get virtualservice bookinfo-a bookinfo-b \
  -n canary-mesh-multi-bookinfo -o yaml

oc get rollout bookinfo-b \
  -n canary-mesh-multi-bookinfo -o yaml

oc get analysisrun \
  -n canary-mesh-multi-bookinfo \
  --sort-by=.metadata.creationTimestamp
```
