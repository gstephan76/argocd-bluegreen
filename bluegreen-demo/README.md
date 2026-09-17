# Argo CD + Argo Rollouts Blue/Green Demo on OpenShift

This repository demonstrates a real **Argo CD + Argo Rollouts blue/green deployment** on Red Hat OpenShift, including a basic **pre-promotion AnalysisRun**.

Argo CD owns desired state from Git. Argo Rollouts owns the runtime deployment lifecycle: ReplicaSets, preview/stable selection, `rollouts-pod-template-hash`, analysis, promotion, abort behavior, and delayed scale-down of the previous stable revision.

This is not a plain OpenShift Route or Service-selector blue/green implementation.

## Architecture

```text
GitHub
  |
  v
Argo CD Application
  |
  v
Rollout + AnalysisTemplate + Services + Routes
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
                                  |
                                  v
                         pre-promotion AnalysisRun
                                  |
                                  v
                            HTTP smoke-test Job
                                  |
                     +------------+------------+
                     |                         |
                  failure                    success
                     |                         |
                     v                         v
                    abort             manual promotion gate
                                               |
                                               v
                                      ACTIVE -> GREEN
```

The OpenShift Routes remain fixed:

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
├── analysis-template.yaml
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

The cluster must already have Red Hat OpenShift GitOps installed with the Argo CD and Argo Rollouts CRDs.

Required workstation commands:

```text
oc
git
```

The promotion script requires the Argo Rollouts `oc` plugin:

```bash
oc argo rollouts version
```

You must already be logged into the OpenShift cluster:

```bash
oc whoami
```

## Quick start

Clone or update the repository:

```bash
git clone https://github.com/gstephan76/argocd-bluegreen.git
cd argocd-bluegreen
```

or:

```bash
git pull --ff-only
```

Deploy the initial BLUE environment:

```bash
bash scripts/deploy-demo.sh
```

Switch from BLUE to GREEN:

```bash
bash scripts/switch-green.sh
```

To create and validate GREEN, run the analysis, but stop before the production switch:

```bash
bash scripts/switch-green.sh --preview-only
```

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

The deployment script:

```text
1. Verifies oc and git.
2. Verifies the OpenShift login.
3. Verifies Application, Rollout, RolloutManager, AnalysisTemplate and AnalysisRun CRDs.
4. Applies bootstrap/.
5. Waits for RolloutManager to become available.
6. Applies argocd/application.yaml.
7. Waits for Argo CD to report Synced.
8. Verifies bluegreen-demo-smoke-test exists.
9. Waits for the initial Rollout and BLUE pods.
10. Prints the active and preview Routes.
```

The bootstrap resources are applied directly because the Argo Rollouts controller must exist before Argo CD can deploy the `Rollout`.

Argo CD manages everything under:

```text
bluegreen-demo/
```

Initial state:

```text
ACTIVE Service  ---> BLUE ReplicaSet
PREVIEW Service ---> BLUE ReplicaSet
```

No pre-promotion AnalysisRun is expected for the initial creation because there is no upgrade to analyze. The analysis is triggered when the pod template changes to a new revision.

Inspect:

```bash
oc get application bluegreen-demo \
  -n openshift-gitops

oc get analysistemplate,rollout,rs,pod,svc,route \
  -n bluegreen-demo

oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo
```

---

# 2. Pre-promotion Analysis

The demo includes:

```text
bluegreen-demo/analysis-template.yaml
```

It defines an Argo Rollouts `AnalysisTemplate` named:

```text
bluegreen-demo-smoke-test
```

The Rollout references it with:

```yaml
strategy:
  blueGreen:
    activeService: bluegreen-demo-active
    previewService: bluegreen-demo-preview

    prePromotionAnalysis:
      templates:
        - templateName: bluegreen-demo-smoke-test
      args:
        - name: preview-url
          value: http://bluegreen-demo-preview.bluegreen-demo.svc.cluster.local

    autoPromotionEnabled: false
```

When GREEN becomes fully available, Argo Rollouts creates an `AnalysisRun` before allowing promotion.

The AnalysisTemplate uses the native **Job metric provider**. The generated Job runs:

```text
quay.io/curl/curl:8.22.0
```

and performs three HTTP requests to the preview Service.

Conceptually:

```text
GREEN pods Ready
      |
      v
AnalysisRun
      |
      v
Job
      |
      +--> GET preview Service
      +--> GET preview Service
      +--> GET preview Service
      |
      +------ exit 0 ------> Successful
      |
      +------ non-zero ----> Failed
```

For a Job metric, a Job completing with exit code zero is a successful metric. A non-zero exit is a failed metric.

If this pre-promotion analysis fails, Argo Rollouts aborts the update before changing the active Service. BLUE therefore remains production.

The analysis is deliberately basic: it validates that the candidate is reachable through the exact preview Service that Argo Rollouts selected. A production implementation could replace or extend this with Prometheus, Service Mesh telemetry, application-level checks, or business metrics.

---

# 3. Switch BLUE to GREEN

Run:

```bash
bash scripts/switch-green.sh
```

The script follows the GitOps path:

```text
Git :blue
   |
   v
change rollout.yaml to :green
   |
   v
git commit + push
   |
   v
Argo CD sync
   |
   v
GREEN ReplicaSet created
   |
   v
PREVIEW Service -> GREEN
ACTIVE Service  -> BLUE
   |
   v
wait for GREEN Ready
   |
   v
pre-promotion AnalysisRun
   |
   v
HTTP smoke-test Job
   |
   +---- failure ---> rollout aborts; ACTIVE remains BLUE
   |
   +---- success
            |
            v
    autoPromotionEnabled=false
            |
            v
       manual pause
            |
            v
 oc argo rollouts promote
            |
            v
 ACTIVE Service -> GREEN
```

The script:

1. Refuses to proceed if tracked Git changes exist.
2. Verifies the local branch matches `origin/<branch>`.
3. Changes `argoproj/rollouts-demo:blue` to `argoproj/rollouts-demo:green`.
4. Commits and pushes the image change.
5. Waits for Argo CD to sync that exact commit.
6. Waits for a distinct GREEN preview ReplicaSet.
7. Waits for GREEN preview pods to become Ready.
8. Waits for the pre-promotion `AnalysisRun`.
9. Requires the AnalysisRun status to become `Successful`.
10. Stops without promotion if `--preview-only` was requested.
11. Otherwise calls `oc argo rollouts promote`.
12. Waits for the active Service to point to the GREEN hash.

If the analysis ends as `Failed`, `Error`, or `Inconclusive`, the script prints diagnostics and exits without issuing a promotion command.

Because Git still contains GREEN after an analysis failure, revert the GREEN commit before retrying so Git desired state matches the intended BLUE production state.

---

# State before promotion

After GREEN is Ready and the analysis succeeds:

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
      |
      v
AnalysisRun = Successful
```

The active and preview hashes should differ:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

Inspect analysis resources:

```bash
oc get analysistemplate,analysisrun,job \
  -n bluegreen-demo
```

Get the current pre-promotion AnalysisRun name:

```bash
ANALYSIS_RUN="$(oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}')"

echo "$ANALYSIS_RUN"
```

Inspect it:

```bash
oc get analysisrun "$ANALYSIS_RUN" \
  -n bluegreen-demo \
  -o yaml
```

View smoke-test Job/Pod output:

```bash
oc get job,pod \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  -o wide

oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  --tail=-1
```

---

# Promotion

After successful analysis, `autoPromotionEnabled: false` still provides the manual gate.

Promote manually:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

Or let `scripts/switch-green.sh` perform that command after it confirms analysis success.

Argo Rollouts switches:

```text
bluegreen-demo-active
        |
        +-- before promotion --> BLUE hash
        |
        +-- after promotion ---> GREEN hash
```

The production OpenShift Route never changes.

The old BLUE ReplicaSet remains available for:

```yaml
scaleDownDelaySeconds: 30
```

and is then scaled down.

---

# Preview-only mode

Run:

```bash
bash scripts/switch-green.sh --preview-only
```

This still waits for:

```text
GREEN Ready
    |
    v
AnalysisRun Successful
```

but does not call `promote`.

The resulting state is:

```text
Production -> BLUE
Preview    -> GREEN
Analysis   -> Successful
```

Promote later with:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

---

# Failure behavior

If the preview HTTP checks fail:

```text
GREEN Ready
    |
    v
AnalysisRun
    |
    v
smoke-test Job fails
    |
    v
AnalysisRun Failed
    |
    v
Rollout Aborted
    |
    v
ACTIVE Service remains BLUE
```

Useful diagnostics:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo

oc get analysisrun \
  -n bluegreen-demo

oc get job,pod \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  -o wide

oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  --tail=-1
```

After diagnosing a failed candidate, revert the GREEN desired-state commit in Git before retrying.

---

# Ownership

Git / Argo CD owns:

- the `Rollout` specification;
- `AnalysisTemplate`;
- desired container image;
- replica count;
- base active/preview Service definitions;
- OpenShift Routes;
- blue/green and analysis configuration.

Argo Rollouts owns:

- stable and preview ReplicaSets;
- `rollouts-pod-template-hash` selectors;
- generated `AnalysisRun`;
- generated analysis Job;
- analysis result;
- pause/promotion state;
- switching the active Service;
- abort behavior;
- delayed scale-down of the previous stable revision.

`argocd/application.yaml` ignores only the Rollouts-owned Service hash selector and uses:

```yaml
RespectIgnoreDifferences=true
```

so Argo CD self-heal does not fight the Rollouts controller.

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

oc get analysistemplate,analysisrun,job \
  -n bluegreen-demo

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

Both scripts support:

```bash
TIMEOUT_SECONDS=600 bash scripts/deploy-demo.sh
TIMEOUT_SECONDS=600 bash scripts/switch-green.sh
```

The default timeout is 300 seconds and the default polling interval is 5 seconds.

Environment overrides:

```text
NAMESPACE
ARGOCD_NAMESPACE
APP_NAME
```
