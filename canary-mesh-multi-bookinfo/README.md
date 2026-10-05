# Multi-Bookinfo canary with OpenShift Service Mesh

`canary-mesh-multi-bookinfo` demonstrates **two independent complete Bookinfo
applications in the same namespace**, each exposed through its own external
OpenShift Route and each represented by its own Argo Rollout.

The independence boundary is the complete application:

- **Bookinfo A** has its own `Rollout/bookinfo-a`.
- **Bookinfo B** has its own `Rollout/bookinfo-b`.
- Only **Bookinfo B** is exercised by the demo workflow.
- Bookinfo A remains parked at its stable baseline throughout the demonstration.

The services inside a Bookinfo application are not independent rollout units.
Traffic is split once, at that Bookinfo application's productpage boundary, and
the selected productpage revision stays on its matching downstream stable or
canary track.

## Architecture

```text
                     namespace: canary-mesh-multi-bookinfo

                         shared Istio ingress
                                  |
                 +----------------+----------------+
                 |                                 |
          external Route A                  external Route B
                 |                                 |
   VirtualService bookinfo-a-rollout       VirtualService bookinfo-b
                 |                                 |
          Rollout bookinfo-a                Rollout bookinfo-b
          parked at 100/0                  exercised by demo
             /      \                         /      \
        stable      canary                 stable    canary
          |            |                     |          |
      complete A    complete A           complete B  complete B
      stable stack  canary stack         stable stack canary stack
```

Both routes target the same dedicated Istio ingress gateway Service. The two
VirtualServices are isolated by the OpenShift-generated route authority:

```text
bookinfo-a-canary-mesh-multi-bookinfo.<apps-domain>
bookinfo-b-canary-mesh-multi-bookinfo.<apps-domain>
```

## One Rollout per Bookinfo

Each Bookinfo application owns exactly one front-door Rollout:

```text
Rollout/bookinfo-a
  stableService -> bookinfo-a-productpage-stable
  canaryService -> bookinfo-a-productpage-canary

Rollout/bookinfo-b
  stableService -> bookinfo-b-productpage-stable
  canaryService -> bookinfo-b-productpage-canary
```

The Rollout does not independently control `details`, `reviews`, and `ratings`.
Instead, each productpage revision points to the matching complete downstream
track.

### Bookinfo A

Bookinfo A is fully rollout-capable but is deliberately **not exercised** by the
demo scripts.

Its baseline path is:

```text
bookinfo-a-productpage-stable
  -> bookinfo-a-details-stable
  -> bookinfo-a-reviews-stable (v2 / black stars)
       -> bookinfo-a-ratings-stable
```

Its candidate path is already declared and isolated:

```text
bookinfo-a-productpage-canary
  -> bookinfo-a-details-canary
  -> bookinfo-a-reviews-canary (v3 / red stars)
       -> bookinfo-a-ratings-canary
```

During this demo, Bookinfo A must remain:

```text
phase == Healthy
stableRS == currentPodHash
marker == bookinfo-a-baseline-stable
stable traffic == 100%
canary traffic == 0%
```

Bookinfo A's strategy is intentionally guarded with manual pauses. A template
change does not automatically drive its traffic through the canary sequence.

### Bookinfo B

Bookinfo B is the Rollout exercised by the demo.

Stable path:

```text
bookinfo-b-productpage-stable
  -> bookinfo-b-details-stable
  -> bookinfo-b-reviews-stable (v2 / black stars)
       -> bookinfo-b-ratings-stable
```

Canary path:

```text
bookinfo-b-productpage-canary
  -> bookinfo-b-details-canary
  -> bookinfo-b-reviews-canary (v3 / red stars)
       -> bookinfo-b-ratings-canary
```

Bookinfo B progresses through:

```text
90% stable / 10% canary -> analysis
75% stable / 25% canary -> analysis
50% stable / 50% canary -> analysis
25% stable / 75% canary -> analysis
0% stable / 100% canary -> analysis
manual approval
```

Its AnalysisTemplate probes the candidate-only productpage Service and checks
HTTP success, rendered Bookinfo content, reviews-v3 red stars, and Istio metrics
showing that the candidate `details`, `reviews`, and `ratings` workloads were
actually reached.

## Isolation model

Every workload and Service carries the application identity:

```text
app.kubernetes.io/instance=bookinfo-a
```

or:

```text
app.kubernetes.io/instance=bookinfo-b
```

Both applications additionally use:

```text
track=stable
```

or:

```text
track=canary
```

for their downstream application tracks.

This prevents a Service from one Bookinfo application from selecting pods from
the other application even though both live in the same namespace.

## GitOps ownership

The GitOps boundary matches the application independence boundary:

- `canary-mesh-multi-bookinfo-a` owns Bookinfo A and `Rollout/bookinfo-a`.
- `canary-mesh-multi-bookinfo-b` owns Bookinfo B and `Rollout/bookinfo-b`.
- `canary-mesh-multi-bookinfo-shared` owns only the common namespace, ingress
  gateway, Gateway, and shared Istio proxy monitoring.

The A and B Argo CD Applications both ignore the runtime fields owned by Argo
Rollouts. Bookinfo A deliberately uses `VirtualService/bookinfo-a-rollout`
instead of reusing the historical static `VirtualService/bookinfo-a`. This makes
the static-to-Rollout migration bootstrap-safe: the new weighted VirtualService
is created with its declared 100/0 weights before Rollouts takes ownership, while
the old static VirtualService is pruned.

The ignored runtime fields are:

- `rollouts-pod-template-hash` on their stable and canary productpage Services;
- the runtime weights on their own `VirtualService` `primary` route.

This allows the two Rollout controllers to operate independently without Argo CD
self-heal fighting their runtime traffic state.

## Prerequisites

The demo does **not** install or reconcile OpenShift Service Mesh.

It requires the same platform prerequisites as `canary-mesh-bookinfo`:

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

`deploy` reconciles both Rollout-capable Bookinfo applications and the shared
infrastructure without changing an active rollout state.

`prepare` establishes the known initial condition for **both** Rollouts:

```text
Bookinfo A = Healthy, stable=100%, canary=0%
Bookinfo B = Healthy, stable=100%, canary=0%
```

After both Rollouts are safely back at that baseline, `prepare` also removes
historical `AnalysisRun` objects and scaled-down ReplicaSets owned by each
Rollout. The current stable ReplicaSet and the Rollout CR itself are preserved.
This keeps the Argo CD resource tree compact between demo runs without causing
the productpage workload to be recreated. Set `CLEAN_ROLLOUT_HISTORY=0` to
preserve the history for troubleshooting.

`start` mutates and exercises **only Bookinfo B**. It refuses to begin if Bookinfo
A is not still parked at its baseline.

Observe both Rollouts:

```bash
oc argo rollouts get rollout bookinfo-a \
  -n canary-mesh-multi-bookinfo

oc argo rollouts get rollout bookinfo-b \
  -n canary-mesh-multi-bookinfo \
  --watch
```

During the demo, Bookinfo A should remain Healthy while Bookinfo B progresses
through its canary steps.

Sample both external routes:

```bash
REQUESTS_A=20 REQUESTS_B=200 \
bash scripts/sample-canary-mesh-multi-bookinfo.sh
```

Expected behavior:

```text
Bookinfo A: stable=100% canary=0%, black-star responses only
Bookinfo B: response distribution follows the active Rollout weight
```

At Bookinfo B's final 100% candidate pause:

```bash
bash scripts/promote-canary-mesh-multi-bookinfo.sh
```

Promotion affects only `Rollout/bookinfo-b`.

Reset the complete demo for another run:

```bash
bash scripts/prepare-canary-mesh-multi-bookinfo.sh
```

`prepare` restores both Rollouts to their baseline, although under the normal demo
workflow Bookinfo A should already be there.

## Idempotency

The operational scripts are designed to converge on their requested state.

`deploy` may be rerun without manufacturing a new Rollout revision or forcing an
active Rollout back to baseline.

`prepare` may be rerun at baseline, during Bookinfo B's rollout, at the final
pause, or after promotion. It restores and verifies both A and B baselines,
creates a Git commit only when the declarative baseline actually changed, and
by default cleans completed Rollout history from the cluster after convergence.
The cleanup is idempotent and never deletes the current stable ReplicaSet.

`start` operates only on Bookinfo B and reuses an already-declared Bookinfo B
candidate instead of creating another timestamped revision.

`promote` operates only on Bookinfo B and treats an already-promoted B candidate
as a verified no-op.

The scripts refuse to silently commit unrelated tracked Git changes.

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

The current VirtualServices expose `/productpage` and the supporting Bookinfo
paths rather than bare `/`.

## Useful checks

```bash
bash scripts/check-canary-mesh-multi-bookinfo-dataplane.sh

oc get rollout bookinfo-a bookinfo-b \
  -n canary-mesh-multi-bookinfo

oc get pods -n canary-mesh-multi-bookinfo \
  -L app.kubernetes.io/instance,app.kubernetes.io/name,track

oc get route bookinfo-a bookinfo-b \
  -n canary-mesh-multi-bookinfo

oc get virtualservice bookinfo-a-rollout bookinfo-b \
  -n canary-mesh-multi-bookinfo -o yaml

oc get analysisrun \
  -n canary-mesh-multi-bookinfo \
  --sort-by=.metadata.creationTimestamp
```
