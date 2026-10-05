# full-demo: shared VirtualService, header-selected Bookinfo, independent Rollouts

`full-demo` is based on `canary-mesh-multi-bookinfo` and preserves its working
contracts while replacing the two external OpenShift Routes and two application
VirtualServices with **one external Route and one shared Istio VirtualService**.

Namespace:

```text
canary-mesh-full-demo
```

The shared ingress selector is:

```text
x-bookinfo-target: a  -> Bookinfo A
x-bookinfo-target: b  -> Bookinfo B
```

The application boundary remains unchanged:

- `Rollout/bookinfo-a` is independent and remains parked at 100/0 in the demo.
- `Rollout/bookinfo-b` is independent and is the only rollout exercised.
- Each selected productpage revision stays on its own complete stable/canary
  downstream stack (`details`, `reviews`, `ratings`).
- Both applications share one dedicated Istio ingress gateway, one OpenShift
  Route, and one `VirtualService/full-demo-router`.

## Request flow

```text
client
  |
  | HTTPS + x-bookinfo-target: a|b
  v
OpenShift Route/full-demo
  |
  v
Service/istio-ingressgateway
  |
  v
Gateway/canary-mesh-full-demo-gateway
  |
  v
VirtualService/full-demo-router
  |
  +-- x-bookinfo-target=a --> HTTP route bookinfo-a-primary
  |                           +--> A stable Service
  |                           +--> A canary Service
  |
  +-- x-bookinfo-target=b --> HTTP route bookinfo-b-primary
                              +--> B stable Service
                              +--> B canary Service
```

Argo Rollouts manages only the weights of its own named HTTP route inside the
shared VirtualService:

```text
Rollout/bookinfo-a -> full-demo-router / bookinfo-a-primary
Rollout/bookinfo-b -> full-demo-router / bookinfo-b-primary
```

The shared Argo CD Application owns the VirtualService and ignores only those
runtime route weights. Bookinfo A and B keep separate Argo CD Applications and
separate Rollout CRs.

## Preserved requirements from canary-mesh-multi-bookinfo

The new demo intentionally keeps the proven behavior of the source demo:

- OpenShift Service Mesh 3.4+ is a prerequisite; the demo never installs or
  reconciles the mesh control plane.
- Sail `Istio/default` and `IstioCNI/default` must already be Ready.
- one namespace with strong `app.kubernetes.io/instance` and `track` isolation;
- one independent Rollout per complete Bookinfo application;
- only Bookinfo B is exercised;
- Bookinfo A remains Healthy at stable=100%, canary=0%;
- Bookinfo B uses 10/25/50/75/100 traffic steps, Prometheus AnalysisRuns, and a
  final manual pause;
- blackbox probing validates the isolated B canary full stack;
- OpenShift user-workload monitoring and Istio proxy metrics are used;
- the dedicated ingress gateway is namespace-local and selector-isolated;
- GitOps ownership is split into shared, A, and B Argo CD Applications;
- `prepare` owns the heavy prerequisite, Git, baseline, data-plane, and cleanup
  validation;
- `start` and `promote` default to an expedited live-demo path;
- scripts are bounded, diagnostic, Git-safe, and idempotent;
- `prepare` removes historical AnalysisRuns and stale ReplicaSets by default but
  preserves the current stable ReplicaSet and Rollout CRs.

## Shared VirtualService

`VirtualService/full-demo-router` contains two named weighted routes:

```text
bookinfo-a-primary:
  match x-bookinfo-target=a
  route bookinfo-a-productpage-stable/canary

bookinfo-b-primary:
  match x-bookinfo-target=b
  route bookinfo-b-productpage-stable/canary
```

The header must be present on each ingress request. This is ideal for CLI/demo
traffic. For a browser, use a mechanism that injects the header on every request
(including `/static` requests), otherwise subrequests will not match a route.

## Exact demo order

From the repository root:

```bash
bash scripts/deploy-canary-mesh-full-demo.sh
bash scripts/prepare-canary-mesh-full-demo.sh
bash scripts/start-canary-mesh-full-demo.sh
```

Watch Bookinfo B in another terminal:

```bash
oc argo rollouts get rollout bookinfo-b \
  -n canary-mesh-full-demo \
  --watch
```

Watch its weights directly in the shared VirtualService:

```bash
watch -n 1 'oc get virtualservice full-demo-router \
  -n canary-mesh-full-demo \
  -o jsonpath="stable={.spec.http[?(@.name==\"bookinfo-b-primary\")].route[0].weight}% canary={.spec.http[?(@.name==\"bookinfo-b-primary\")].route[1].weight}%{\"\\n\"}"'
```

Generate traffic through the single Route:

```bash
REQUESTS_A=20 REQUESTS_B=200 \
bash scripts/sample-canary-mesh-full-demo.sh
```

At the final 100% candidate pause:

```bash
bash scripts/promote-canary-mesh-full-demo.sh
```

After the demo, reset and clean history:

```bash
bash scripts/prepare-canary-mesh-full-demo.sh
```

## Direct request examples

```bash
HOST="$(oc get route full-demo \
  -n canary-mesh-full-demo \
  -o jsonpath='{.spec.host}')"

curl -sk \
  -H 'x-bookinfo-target: a' \
  "https://${HOST}/productpage"

curl -sk \
  -H 'x-bookinfo-target: b' \
  "https://${HOST}/productpage"
```

## Operational semantics

```text
deploy  = reconcile shared ingress/router plus both Bookinfo applications
prepare = heavy validation + 100/0 baseline + cleanup
start   = fast GitOps declaration and progressive rollout of Bookinfo B only
promote = fast final manual approval of Bookinfo B
prepare = reset/clean for the next demonstration
```

For troubleshooting, set `FAST_DEMO_PATH=0` on `start` or `promote` to run the
full data-plane validation around the operation. Set `CLEAN_ROLLOUT_HISTORY=0`
on `prepare` to preserve rollout history.
