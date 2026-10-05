# Whole-application Bookinfo canary with OpenShift Service Mesh

`canary-mesh-bookinfo` is a separate demo from `canary-mesh-demo`.

The original mesh demo progressively routes traffic between two revisions of one
small workload. This demo treats **the complete Bookinfo request path** as the
canary unit.

## Architecture

```text
OpenShift Route
      |
      v
Istio ingress gateway
      |
      v
Argo Rollouts / Istio VirtualService
      |
      +---------------- stable ----------------+
      |                                        |
      v                                        v
productpage stable                      productpage canary
      |                                        |
      +--> details-stable                      +--> details-canary
      +--> reviews-stable                      +--> reviews-canary
              |                                        |
              +--> ratings-stable                      +--> ratings-canary
```

The ingress weight decides whether a request enters the stable or candidate
Bookinfo revision. After that decision, downstream calls stay on the same track:

```text
stable:
productpage-stable
  -> details-stable
  -> reviews-stable
       -> ratings-stable

canary:
productpage-canary
  -> details-canary
  -> reviews-canary
       -> ratings-canary
```

A request is never intentionally mixed across tracks. Candidate productpage uses
only candidate downstream Services, and stable productpage uses only stable
downstream Services.

## What is canaried

All four Bookinfo services participate:

| Service | Stable track | Canary track |
|---|---|---|
| productpage | stable ReplicaSet selected by Argo Rollouts | candidate ReplicaSet selected by Argo Rollouts |
| details | `bookinfo-details-stable` | `bookinfo-details-canary` |
| reviews | v2 / black stars | v3 / red stars |
| ratings | `bookinfo-ratings-stable` | `bookinfo-ratings-canary` |

`details` and `ratings` intentionally use the same container version on both
tracks. They are still separate pods and Services, which demonstrates that a
whole-application revision can include components whose binary did not change.

Argo Rollouts owns the front-door productpage rollout and the Istio traffic
weight. The stable/canary downstream Deployments are declared by Argo CD in
parallel. This avoids running four independent rollout percentages that could
produce cross-version request paths.

## Canary sequence

The rollout progresses through:

```text
90% stable / 10% whole-app canary -> analysis
75% stable / 25% whole-app canary -> analysis
50% stable / 50% whole-app canary -> analysis
25% stable / 75% whole-app canary -> analysis
0% stable / 100% whole-app canary -> analysis
manual approval
```

Each candidate health gate probes the canary-only productpage Service and
requires:

- HTTP 200;
- `Book Details`;
- `Book Reviews`;
- rendered review stars from reviews v3;
- Istio request metrics proving that the candidate path reached canary
  `details`, `reviews`, and `ratings`.

A healthy stable stack therefore cannot hide a broken candidate.

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

The dedicated ingress gateway uses the isolated compound selector:

```text
istio=ingressgateway
app.kubernetes.io/component=canary-mesh-bookinfo-ingressgateway
```

## Git workflow contract

The `prepare` and `start` scripts intentionally mutate
`canary-mesh-bookinfo/rollout.yaml`, commit the desired state, and push it to the
current branch so Argo CD remains the source of truth.

Before running them, the local repository must:

- have no tracked uncommitted changes;
- not be in detached HEAD state;
- match `origin/<current-branch>`.

The scripts refuse to continue if those conditions are not met.

## Demo workflow

From the repository root:

```bash
bash scripts/deploy-canary-mesh-bookinfo.sh
bash scripts/prepare-canary-mesh-bookinfo.sh
bash scripts/start-canary-mesh-bookinfo.sh
```

`deploy` creates/reconciles the GitOps application and supporting platform
resources. `prepare` establishes a trusted stable baseline. `start` creates a
fresh candidate marker, switches productpage to the canary downstream Services,
commits that desired state, and lets Argo Rollouts execute the progressive
traffic sequence.

Watch the rollout:

```bash
oc argo rollouts get rollout canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  --watch
```

Watch the current Istio weights:

```bash
watch -n 1 "oc get virtualservice canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  -o jsonpath='stable={.spec.http[0].route[0].weight}% canary={.spec.http[0].route[1].weight}%{\"\\n\"}'"
```

Sample the real whole-application distribution:

```bash
REQUESTS=200 \
bash scripts/sample-canary-mesh-bookinfo.sh
```

Stable responses are identified by reviews-v2 black stars. Candidate responses
are identified by reviews-v3 red stars.

## User-facing URL

The current Istio `VirtualService` exposes the Bookinfo application at:

```text
https://<route-host>/productpage
```

For example:

```bash
HOST="$(oc get route canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  -o jsonpath='{.spec.host}')"

curl -sS "https://${HOST}/productpage"
```

The current VirtualService does not match bare `/`, so `https://<route-host>/`
returns an Istio 404. Use `/productpage` for this version of the demo.

## Promotion

After all five analysis gates succeed, the rollout pauses at 100% candidate
traffic. Promotion is deliberately manual:

```bash
bash scripts/promote-canary-mesh-bookinfo.sh
```

The promotion script verifies that:

- the Rollout is at the final manual pause;
- the desired revision is a Bookinfo candidate;
- the complete Service Mesh data plane is healthy;
- at least five successful candidate AnalysisRuns exist;
- the candidate ReplicaSet becomes the stable ReplicaSet.

After promotion, the candidate is the active stable productpage revision.

## Returning to the initial state

`prepare-canary-mesh-bookinfo.sh` is also the reset/recovery command for the
demo. It can be run:

- before the first canary;
- while a canary is progressing;
- at the final 100% candidate pause;
- after the candidate has already been promoted;
- again when the baseline is already healthy.

Run:

```bash
bash scripts/prepare-canary-mesh-bookinfo.sh
```

The script restores the declarative productpage baseline in Git:

```text
demo-bookinfo-revision = bookinfo-baseline-stable
track                  = stable
DETAILS_HOSTNAME       = bookinfo-details-stable
REVIEWS_HOSTNAME       = bookinfo-reviews-stable
RATINGS_HOSTNAME       = bookinfo-ratings-stable
```

If that differs from the current Git state, `prepare` commits and pushes the
baseline, hard-refreshes the Argo CD Application, waits for the exact Git
revision to reconcile, and then recovers the baseline Rollout.

If a candidate is still active or has already been promoted, the restored
baseline becomes a new Rollout revision. The script uses a full Rollouts
promotion when necessary and waits until:

```text
phase == Healthy
stableRS == currentPodHash
demo-bookinfo-revision == bookinfo-baseline-stable
productpage -> details-stable
productpage -> reviews-stable
productpage -> ratings-stable
```

It then runs the complete Bookinfo Service Mesh data-plane check before reporting
the baseline ready.

### What reset does not delete

The downstream candidate Deployments and Services remain present:

```text
bookinfo-details-canary
bookinfo-reviews-canary
bookinfo-ratings-canary
```

They are declarative resources managed by Argo CD and are intentionally kept
ready for the next demo cycle. Reset changes the active productpage revision back
to the stable downstream track; it does not tear down and recreate the candidate
stack.

### Degraded rollouts

The current recovery path deliberately refuses to declare success if the Rollout
becomes `Degraded`. Diagnose and correct the failure before using `prepare` as a
normal reset path.

## Recommended demo cycles

Normal cycle:

```text
deploy
  -> prepare
  -> start
  -> 10/25/50/75/100 analysis
  -> promote
  -> prepare
```

Abort/reset during a rollout:

```text
prepare
  -> start
  -> candidate in progress
  -> prepare
  -> stable baseline restored
```

Reset after promotion:

```text
prepare
  -> start
  -> promote
  -> candidate becomes stable
  -> prepare
  -> original baseline becomes stable again
```

## Useful checks

Validate the whole mesh data plane:

```bash
bash scripts/check-canary-mesh-bookinfo-dataplane.sh
```

Inspect the Rollout:

```bash
oc get rollout canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  -o yaml
```

Inspect Istio routing:

```bash
oc get virtualservice canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  -o yaml
```

Inspect the stable/canary workloads:

```bash
oc get pods -n canary-mesh-bookinfo \
  -L app,track,version
```

Inspect analysis history:

```bash
oc get analysisrun \
  -n canary-mesh-bookinfo \
  --sort-by=.metadata.creationTimestamp
```

Inspect the current downstream targets selected by productpage:

```bash
oc get rollout canary-mesh-bookinfo \
  -n canary-mesh-bookinfo \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
```
