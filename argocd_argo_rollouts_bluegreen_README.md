# Argo CD + Argo Rollouts Blue/Green on OpenShift

This demo implements **Argo Rollouts blue/green deployment** on Red Hat OpenShift.

It does **not** implement blue/green by manually changing an OpenShift Service selector.
Argo CD manages the desired manifests in Git, while the **Argo Rollouts controller**
creates the old/new ReplicaSets and injects `rollouts-pod-template-hash` into the
active and preview Services to control which ReplicaSet each Service reaches.

## Architecture

```text
                           OpenShift Route
                         bluegreen-demo
                                |
                                v
                  bluegreen-demo-active Service
                                |
                     Rollouts-managed hash
                                |
                                v
                       ACTIVE ReplicaSet
                         BLUE initially


                    OpenShift preview Route
                    bluegreen-demo-preview
                                |
                                v
                 bluegreen-demo-preview Service
                                |
                     Rollouts-managed hash
                                |
                                v
                       PREVIEW ReplicaSet
                     GREEN during update
```

There is one `Rollout` workload, not separate `Deployment` objects for v1 and v2.

The demo application is `argoproj/rollouts-demo`, an HTTP application whose image
tags display different colors. Initial Git state uses:

```yaml
image: argoproj/rollouts-demo:blue
```

The next version is:

```yaml
image: argoproj/rollouts-demo:green
```

## Repository layout

```text
bootstrap/
├── namespace.yaml
├── rollout-manager.yaml
└── kustomization.yaml

argocd/
└── application.yaml

bluegreen-demo/
├── rollout.yaml
├── service-active.yaml
├── service-preview.yaml
├── route-active.yaml
├── route-preview.yaml
├── kustomization.yaml
└── README.md
```

## 1. Bootstrap Argo Rollouts for the namespace

Red Hat OpenShift GitOps must already be installed.

Create the workload namespace and a namespace-scoped `RolloutManager`:

```bash
oc apply -k bootstrap
```

Verify:

```bash
oc get rolloutmanager -n bluegreen-demo
oc get pods -n bluegreen-demo
oc api-resources | rg -i 'rollout|rolloutmanager'
```

Wait until the Argo Rollouts controller created by the `RolloutManager` is ready.

## 2. Configure the Argo CD Application

Edit:

```text
argocd/application.yaml
```

Replace:

```yaml
repoURL: https://github.com/REPLACE_ME/REPLACE_ME.git
```

with the Git repository containing this directory.

Then create the Argo CD Application:

```bash
oc apply -f argocd/application.yaml
```

Inspect it:

```bash
oc get application bluegreen-demo   -n openshift-gitops
```

The Application uses automated sync/self-heal.

Argo Rollouts dynamically adds this key to both Services:

```text
rollouts-pod-template-hash
```

The Application therefore ignores **only that key** and uses
`RespectIgnoreDifferences=true`, so Argo CD continues to own the Services without
removing the selector hash owned by Argo Rollouts.

## 3. Initial deployment: BLUE is active

The initial Rollout contains:

```yaml
image: argoproj/rollouts-demo:blue
```

Argo CD synchronizes the manifests and Argo Rollouts creates the initial ReplicaSet.

Watch the rollout:

```bash
oc argo rollouts get rollout bluegreen-demo   -n bluegreen-demo   --watch
```

Inspect the generated ReplicaSet and Service selectors:

```bash
oc get rollout,rs,pod   -n bluegreen-demo   -o wide

oc get svc bluegreen-demo-active bluegreen-demo-preview   -n bluegreen-demo   -o yaml
```

On the first deployment, both active and preview Services resolve to the initial
stable ReplicaSet.

Test production:

```bash
curl -k   "https://$(oc get route bluegreen-demo     -n bluegreen-demo     -o jsonpath='{.spec.host}')"
```

Test preview:

```bash
curl -k   "https://$(oc get route bluegreen-demo-preview     -n bluegreen-demo     -o jsonpath='{.spec.host}')"
```

Both initially show the BLUE application.

## 4. Start BLUE -> GREEN through Git

Do **not** create an `app-v2 Deployment` and do **not** manually switch the active
Service selector.

Edit:

```text
bluegreen-demo/rollout.yaml
```

Change:

```yaml
image: argoproj/rollouts-demo:blue
```

to:

```yaml
image: argoproj/rollouts-demo:green
```

Commit and push:

```bash
git add bluegreen-demo/rollout.yaml
git diff --cached --check
git commit -m "Deploy green preview"
git push
```

Argo CD detects the new desired `Rollout.spec.template` and synchronizes it.

Argo Rollouts then performs the blue/green mechanics:

```text
                   ACTIVE SERVICE
                         |
                         v
                 BLUE ReplicaSet
                  production


                   PREVIEW SERVICE
                         |
                         v
                 GREEN ReplicaSet
                    candidate
```

Because:

```yaml
autoPromotionEnabled: false
```

the rollout pauses after GREEN becomes ready.

Watch it:

```bash
oc argo rollouts get rollout bluegreen-demo   -n bluegreen-demo   --watch
```

## 5. Validate GREEN through the preview Route

Production must still be BLUE:

```bash
curl -k   "https://$(oc get route bluegreen-demo     -n bluegreen-demo     -o jsonpath='{.spec.host}')"
```

The preview Route must be GREEN:

```bash
curl -k   "https://$(oc get route bluegreen-demo-preview     -n bluegreen-demo     -o jsonpath='{.spec.host}')"
```

You can also prove that Rollouts assigned different hashes:

```bash
oc get svc bluegreen-demo-active bluegreen-demo-preview   -n bluegreen-demo   -o jsonpath='{range .items[*]}{.metadata.name}{"  hash="}{.spec.selector.rollouts-pod-template-hash}{"
"}{end}'
```

Before promotion, the active and preview hashes should be different.

## 6. Promote GREEN

After validation, promote the paused rollout:

```bash
oc argo rollouts promote bluegreen-demo   -n bluegreen-demo
```

Argo Rollouts changes the `bluegreen-demo-active` Service hash to the GREEN
ReplicaSet hash.

The production Route itself does not change:

```text
OpenShift Route
      |
      v
active Service
      |
      +-- before promotion --> BLUE ReplicaSet
      |
      +-- after promotion ---> GREEN ReplicaSet
```

Verify:

```bash
oc argo rollouts get rollout bluegreen-demo   -n bluegreen-demo

curl -k   "https://$(oc get route bluegreen-demo     -n bluegreen-demo     -o jsonpath='{.spec.host}')"
```

Production now shows GREEN.

The old BLUE ReplicaSet remains alive for `scaleDownDelaySeconds: 30`, then Argo
Rollouts scales it down.

## 7. GitOps rollback

Because Git is the desired state, a durable rollback should also start in Git.

Revert the image to:

```yaml
image: argoproj/rollouts-demo:blue
```

Commit and push:

```bash
git add bluegreen-demo/rollout.yaml
git diff --cached --check
git commit -m "Rollback rollout to blue"
git push
```

Argo CD synchronizes the reverted pod template. Argo Rollouts makes BLUE the new
preview candidate while GREEN remains active.

Validate the preview Route, then promote:

```bash
oc argo rollouts promote bluegreen-demo   -n bluegreen-demo
```

Production is then switched back to BLUE by Argo Rollouts.

## 8. Abort a candidate before promotion

If GREEN fails validation while the rollout is paused:

```bash
oc argo rollouts abort bluegreen-demo   -n bluegreen-demo
```

Production remains on the stable BLUE ReplicaSet.

Also revert the failed image change in Git so that Argo CD desired state agrees
with the intended stable version.

## Useful diagnostics

```bash
oc argo rollouts get rollout bluegreen-demo   -n bluegreen-demo

oc get rollout bluegreen-demo   -n bluegreen-demo   -o yaml

oc get rs,pod   -n bluegreen-demo   -l app=bluegreen-demo   -o wide

oc get svc bluegreen-demo-active bluegreen-demo-preview   -n bluegreen-demo   -o yaml

oc get route   -n bluegreen-demo

oc describe rollout bluegreen-demo   -n bluegreen-demo
```

## Key ownership rule

Git / Argo CD owns:

- the `Rollout` specification;
- base Service definitions;
- Routes;
- replica count;
- container image desired state;
- blue/green strategy configuration.

Argo Rollouts owns the runtime rollout state, including:

- stable and preview ReplicaSets;
- `rollouts-pod-template-hash` selectors;
- pause/promotion state;
- switching active traffic from the stable ReplicaSet to the preview ReplicaSet;
- delayed scale-down of the previous active ReplicaSet.

That ownership boundary is the essential difference between this implementation
and a plain OpenShift Service-selector blue/green deployment.
