# Argo CD + Argo Rollouts Blue/Green Demo on OpenShift

This repository demonstrates a real **Argo CD + Argo Rollouts blue/green deployment** on Red Hat OpenShift.

Argo CD owns the desired state from Git. Argo Rollouts owns the runtime blue/green mechanics: ReplicaSets, preview/stable selection, `rollouts-pod-template-hash`, promotion, and delayed scale-down of the previous stable revision.

This is **not** a plain OpenShift blue/green implementation where an operator manually changes a Service selector.

## Architecture

```text
GitHub
  |
  v
Argo CD Application
  |
  v
Rollout + Services + Routes
  |
  v
Argo Rollouts controller
  |
  +-------------------------------+
  |                               |
  v                               v
ACTIVE Service                PREVIEW Service
  |                               |
  v                               v
BLUE ReplicaSet               GREEN ReplicaSet
production                    candidate
```

The OpenShift Routes never need to switch targets:

```text
bluegreen-demo Route
        |
        v
bluegreen-demo-active Service
        |
        v
Rollouts-selected active ReplicaSet

bluegreen-demo-preview Route
        |
        v
bluegreen-demo-preview Service
        |
        v
Rollouts-selected preview ReplicaSet
```

## Repository layout

```text
argocd/
└── application.yaml

bootstrap/
├── namespace.yaml
├── rollout-manager.yaml
└── kustomization.yaml

bluegreen-demo/
├── rollout.yaml
├── service-active.yaml
├── service-preview.yaml
├── route-active.yaml
├── route-preview.yaml
├── kustomization.yaml
└── README.md

scripts/
├── deploy-demo.sh
└── switch-green.sh
```

## Prerequisites

The cluster must already have Red Hat OpenShift GitOps installed, including the Argo CD `Application` CRD and the Argo Rollouts / `RolloutManager` CRDs.

The workstation needs:

```text
oc
git
```

The GREEN promotion script also requires the Argo Rollouts `oc` plugin:

```bash
oc argo rollouts version
```

You must already be logged into the target OpenShift cluster:

```bash
oc whoami
```

## Quick start

Clone or update the repository:

```bash
git clone https://github.com/gstephan76/argocd-bluegreen.git
cd argocd-bluegreen
```

If the repository already exists locally:

```bash
git pull --ff-only
```

Deploy the initial BLUE environment:

```bash
bash scripts/deploy-demo.sh
```

Then switch from BLUE to GREEN:

```bash
bash scripts/switch-green.sh
```

To create GREEN only as preview and stop before promotion:

```bash
bash scripts/switch-green.sh --preview-only
```

The scripts are intentionally separated so the initial Argo CD deployment and the later application promotion are two distinct operations.

---

# 1. Initial BLUE deployment

The repository initially defines:

```yaml
image: argoproj/rollouts-demo:blue
```

Run:

```bash
bash scripts/deploy-demo.sh
```

The script performs the following operations:

```text
1. Verify oc and git.
2. Verify OpenShift login.
3. Verify Application, Rollout and RolloutManager CRDs.
4. Apply bootstrap/.
5. Wait for RolloutManager to become available.
6. Apply argocd/application.yaml.
7. Wait for Argo CD to report the Application Synced.
8. Wait for the Rollout and BLUE pods.
9. Display active and preview Routes.
10. Display the Argo Rollouts state when the plugin is available.
```

The bootstrap resources are applied directly because the Argo Rollouts controller must exist before it can reconcile the `Rollout` workload managed by Argo CD.

Argo CD then manages everything under:

```text
bluegreen-demo/
```

The expected initial state is:

```text
ACTIVE Service  ---> BLUE ReplicaSet
PREVIEW Service ---> BLUE ReplicaSet
```

Both Routes therefore initially show BLUE.

Inspect the state manually:

```bash
oc get application bluegreen-demo \
  -n openshift-gitops

oc get rollout,rs,pod,svc,route \
  -n bluegreen-demo

oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo
```

Get the URLs:

```bash
ACTIVE_URL="https://$(oc get route bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='{.spec.host}')"

PREVIEW_URL="https://$(oc get route bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{.spec.host}')"

echo "$ACTIVE_URL"
echo "$PREVIEW_URL"
```

---

# 2. Switch BLUE to GREEN

Run:

```bash
bash scripts/switch-green.sh
```

The script implements the GitOps rollout rather than manually editing the OpenShift Service.

It performs this sequence:

```text
Git image :blue
     |
     v
change rollout.yaml to :green
     |
     v
git commit + git push
     |
     v
Argo CD sync
     |
     v
Argo Rollouts creates GREEN ReplicaSet
     |
     +--------------------------+
     |                          |
     v                          v
ACTIVE Service             PREVIEW Service
BLUE                       GREEN
production                 candidate
     |                          |
     |                    wait for Ready
     |                          |
     +--------------------------+
                 |
                 v
       oc argo rollouts promote
                 |
                 v
ACTIVE Service ----------> GREEN
                 |
                 v
GREEN is production
```

The script refuses to continue if tracked local Git changes exist, or if the local branch is either ahead of or behind its matching `origin/<branch>`. This prevents the demo script from accidentally pushing unrelated local commits.

It then:

1. Changes `argoproj/rollouts-demo:blue` to `argoproj/rollouts-demo:green`.
2. Runs `git diff --cached --check`.
3. Commits the image change.
4. Pushes the current branch to `origin`.
5. Waits until the Argo CD `Application` has synchronized that exact Git commit.
6. Waits until the preview Service points to a different Rollouts hash from the active Service.
7. Verifies the preview ReplicaSet is actually running `argoproj/rollouts-demo:green`.
8. Waits for the GREEN preview pods to become Ready.
9. Prints the BLUE production URL and GREEN preview URL.
10. If `--preview-only` was requested, stops here with BLUE still active.
11. Otherwise runs `oc argo rollouts promote`.
12. Waits until the active Service points to the GREEN hash.

Because `autoPromotionEnabled: false`, GREEN cannot become production merely because Argo CD synchronized the new image. Argo Rollouts pauses at the preview stage until promotion occurs.

## State immediately before promotion

```text
Production Route
      |
      v
bluegreen-demo-active
      |
      v
BLUE hash
      |
      v
BLUE ReplicaSet

Preview Route
      |
      v
bluegreen-demo-preview
      |
      v
GREEN hash
      |
      v
GREEN ReplicaSet
```

You can inspect the hashes with:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

Before promotion they should be different.

## State after promotion

After:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

Argo Rollouts changes the active Service hash to GREEN:

```text
Production Route
      |
      v
bluegreen-demo-active
      |
      v
GREEN hash
      |
      v
GREEN ReplicaSet
```

The production Route itself does not change.

The previous BLUE ReplicaSet remains available for the configured delay:

```yaml
scaleDownDelaySeconds: 30
```

and is then scaled down by Argo Rollouts.

---

# Argo CD ownership vs Argo Rollouts ownership

Git / Argo CD owns:

- the `Rollout` specification;
- the desired container image;
- replica count;
- active and preview Service base definitions;
- OpenShift Routes;
- blue/green strategy configuration.

Argo Rollouts owns runtime rollout state:

- stable and preview ReplicaSets;
- `rollouts-pod-template-hash` selectors;
- pause/promotion state;
- switching the active Service to the preview revision;
- delayed scale-down of the previous revision.

`argocd/application.yaml` therefore ignores only this controller-owned Service field:

```text
.spec.selector.rollouts-pod-template-hash
```

and enables:

```yaml
RespectIgnoreDifferences=true
```

This prevents Argo CD self-heal from fighting the Argo Rollouts controller while leaving the rest of the Services Git-managed.

---

# Manual deployment commands

The scripts automate these commands, but the equivalent manual initial deployment is:

```bash
oc apply -k bootstrap

oc get rolloutmanager argo-rollout \
  -n bluegreen-demo

oc apply -f argocd/application.yaml

oc get application bluegreen-demo \
  -n openshift-gitops \
  -w

oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo \
  --watch
```

To manually create the GREEN preview, edit:

```text
bluegreen-demo/rollout.yaml
```

from:

```yaml
image: argoproj/rollouts-demo:blue
```

to:

```yaml
image: argoproj/rollouts-demo:green
```

then:

```bash
git add bluegreen-demo/rollout.yaml
git diff --cached --check
git commit -m "Deploy green preview"
git push
```

After GREEN is Ready in preview:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

---

# Abort before promotion

If GREEN is bad while it is still preview-only:

```bash
oc argo rollouts abort bluegreen-demo \
  -n bluegreen-demo
```

Production remains on the stable BLUE ReplicaSet.

Because Git still contains the GREEN desired image, also revert the Git change so Git and runtime intent agree.

---

# Useful diagnostics

```bash
oc get application bluegreen-demo \
  -n openshift-gitops \
  -o yaml

oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo

oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o yaml

oc get rs,pod \
  -n bluegreen-demo \
  -l app=bluegreen-demo \
  -o wide

oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o yaml

oc get route \
  -n bluegreen-demo
```

## Script tuning

The GREEN script also supports preview-only mode:

```bash
bash scripts/switch-green.sh --preview-only
```

Both scripts support environment overrides:

```bash
TIMEOUT_SECONDS=600 bash scripts/deploy-demo.sh
TIMEOUT_SECONDS=600 bash scripts/switch-green.sh
```

The default timeout is 300 seconds and the default poll interval is 5 seconds.

You can also override the namespaces and application name if the manifests are changed accordingly:

```text
NAMESPACE
ARGOCD_NAMESPACE
APP_NAME
```
