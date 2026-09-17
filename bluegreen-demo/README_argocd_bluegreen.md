# Argo CD + Argo Rollouts Blue/Green Deployment on OpenShift

This demo implements a complete **GitOps blue/green deployment** on Red Hat OpenShift using:

- **Argo CD** for GitOps synchronization
- **Argo Rollouts** for blue/green orchestration
- **OpenShift Routes** for stable production and preview endpoints
- **Argo Rollouts Analysis** as a pre-promotion safety gate

The production Route never switches between BLUE and GREEN Services. It always targets the same active Service. Argo Rollouts changes the Service's `rollouts-pod-template-hash` selector to move production traffic between ReplicaSets.

## Architecture

```text
                         Git repository
                              |
                              v
                           Argo CD
                              |
                              v
                           Rollout
                              |
                    Argo Rollouts controller
                     /                    \
                    /                      \
                   v                        v
           BLUE ReplicaSet          GREEN ReplicaSet
              stable                  preview
                 ^                        ^
                 |                        |
        active Service             preview Service
                 ^                        ^
                 |                        |
        production Route            preview Route
```

With pre-promotion analysis:

```text
GREEN ReplicaSet Ready
        |
        v
preview Service
        |
        v
AnalysisRun
        |
        v
HTTP smoke-test Job
        |
   +----+----+
   |         |
 failure   success
   |         |
   v         v
 abort     manual promotion
              |
              v
      active Service -> GREEN
```

## Repository Layout

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

## Responsibilities

**Argo CD owns desired state from Git:**

```text
Rollout
AnalysisTemplate
Services
Routes
container image
replica count
blue/green strategy
analysis configuration
```

**Argo Rollouts owns runtime state:**

```text
stable ReplicaSet
preview ReplicaSet
rollouts-pod-template-hash
AnalysisRun
promotion state
abort state
active Service switching
old ReplicaSet scale-down
```

**OpenShift provides stable Routes:**

```text
bluegreen-demo
bluegreen-demo-preview
```

## Prerequisites

The cluster must have Red Hat OpenShift GitOps installed.

Verify:

```bash
oc get pods -n openshift-gitops
```

Required CRDs:

```bash
oc get crd \
  applications.argoproj.io \
  rollouts.argoproj.io \
  rolloutmanagers.argoproj.io \
  analysistemplates.argoproj.io \
  analysisruns.argoproj.io
```

Required workstation commands:

```text
oc
git
```

Verify the Argo Rollouts plugin:

```bash
oc argo rollouts version
```

Verify OpenShift login:

```bash
oc whoami
```

## Initial BLUE Deployment

The initial desired image is:

```yaml
image: argoproj/rollouts-demo:blue
```

Deploy everything with:

```bash
bash scripts/deploy-demo.sh
```

The script:

```text
1. Validates required commands.
2. Validates the OpenShift login.
3. Validates Argo CD / Rollouts / Analysis CRDs.
4. Applies bootstrap/.
5. Waits for RolloutManager.
6. Applies the Argo CD Application.
7. Waits for Argo CD synchronization.
8. Verifies the AnalysisTemplate exists.
9. Waits for the initial BLUE Rollout.
10. Waits for BLUE pods to become Ready.
11. Prints the active and preview Routes.
```

Expected initial state:

```text
ACTIVE Service  ---> BLUE ReplicaSet
PREVIEW Service ---> BLUE ReplicaSet
```

Both Routes initially show BLUE.

## Verify the Initial Deployment

```bash
oc get application bluegreen-demo \
  -n openshift-gitops
```

Inspect workload resources:

```bash
oc get \
  analysistemplate,rollout,rs,pod,svc,route \
  -n bluegreen-demo
```

Inspect the Rollout:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo
```

Get the production and preview URLs:

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

Initially:

```text
ACTIVE_URL  -> BLUE
PREVIEW_URL -> BLUE
```

## Start the GREEN Deployment

The switch starts by changing:

```yaml
image: argoproj/rollouts-demo:blue
```

to:

```yaml
image: argoproj/rollouts-demo:green
```

The helper script performs this automatically:

```bash
bash scripts/switch-green.sh
```

The script:

```text
1. Verifies the local Git working tree is clean.
2. Verifies the branch matches origin.
3. Changes :blue to :green.
4. Commits the change.
5. Pushes it to Git.
6. Waits for Argo CD to sync the exact commit.
7. Waits for the GREEN ReplicaSet.
8. Waits for GREEN pods to become Ready.
9. Waits for the pre-promotion AnalysisRun.
10. Requires AnalysisRun=Successful.
11. Promotes GREEN.
12. Waits for the active Service to switch to GREEN.
```

## BLUE and GREEN Before Promotion

After Argo CD synchronizes GREEN:

```text
Production Route
      |
      v
bluegreen-demo-active
      |
      v
BLUE ReplicaSet


Preview Route
      |
      v
bluegreen-demo-preview
      |
      v
GREEN ReplicaSet
```

The production Route still serves BLUE.

The preview Route serves GREEN.

Check the Rollouts-managed hashes:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

Before promotion, the hashes should differ.

## Pre-Promotion Analysis

The Rollout references the analysis template with:

```yaml
prePromotionAnalysis:
  templates:
    - templateName: bluegreen-demo-smoke-test
```

The AnalysisTemplate probes:

```text
http://bluegreen-demo-preview.bluegreen-demo.svc.cluster.local
```

Conceptually:

```text
GREEN Ready
    |
    v
AnalysisRun
    |
    v
smoke-test Job
    |
    +---- exit 0 ----> Successful
    |
    +---- non-zero --> Failed
```

Inspect Analysis resources:

```bash
oc get \
  analysistemplate,analysisrun,job \
  -n bluegreen-demo
```

Get the current AnalysisRun:

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

View the smoke-test logs:

```bash
oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  --tail=-1
```

## Manual Promotion Gate

The Rollout uses:

```yaml
autoPromotionEnabled: false
```

So even after analysis succeeds:

```text
ACTIVE    -> BLUE
PREVIEW   -> GREEN
ANALYSIS  -> Successful
PROMOTION -> waiting
```

Promote manually:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

Or let:

```bash
bash scripts/switch-green.sh
```

perform the promotion after successful analysis.

## GREEN After Promotion

After promotion:

```text
Production Route
      |
      v
bluegreen-demo-active
      |
      v
GREEN ReplicaSet
```

The production Route does not change.

Verify:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo
```

Check the Services:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

## Old BLUE ReplicaSet

The Rollout uses:

```yaml
scaleDownDelaySeconds: 30
```

After promotion:

```text
GREEN active
    |
    v
wait 30 seconds
    |
    v
BLUE scales down
```

Inspect:

```bash
oc get rs \
  -n bluegreen-demo \
  -l app=bluegreen-demo
```

## Preview-Only Mode

To deploy GREEN and run the analysis but stop before promotion:

```bash
bash scripts/switch-green.sh --preview-only
```

Result:

```text
Production -> BLUE
Preview    -> GREEN
Analysis   -> Successful
```

Promote later:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

## Analysis Failure

If the smoke test fails:

```text
GREEN preview
     |
     v
AnalysisRun Failed
     |
     v
Rollout Aborted
     |
     v
BLUE remains production
```

Diagnostics:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo

oc get analysisrun \
  -n bluegreen-demo

oc get job,pod \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  -o wide
```

Logs:

```bash
oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  --tail=-1
```

Because Git still requests GREEN, revert the GREEN commit before retrying.

## Abort Before Promotion

If GREEN should not be promoted:

```bash
oc argo rollouts abort bluegreen-demo \
  -n bluegreen-demo
```

BLUE remains production.

Then revert the GREEN Git commit:

```bash
git log --oneline -5
git revert <green-commit-sha>
git push origin main
```

## Roll Back GREEN to BLUE After Promotion

Change the desired image back to:

```yaml
image: argoproj/rollouts-demo:blue
```

Commit and push:

```bash
git add bluegreen-demo/rollout.yaml

git diff --cached --check

git commit -m "Rollback rollout to blue"

git push origin main
```

Argo CD synchronizes BLUE as the next preview candidate.

After the pre-promotion analysis succeeds:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

Production switches back to BLUE.

## Useful Commands

Argo CD:

```bash
oc get application bluegreen-demo \
  -n openshift-gitops \
  -o yaml
```

Rollout:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo
```

ReplicaSets and Pods:

```bash
oc get rs,pod \
  -n bluegreen-demo \
  -l app=bluegreen-demo \
  -o wide
```

Services:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o yaml
```

Routes:

```bash
oc get route \
  -n bluegreen-demo
```

Analysis:

```bash
oc get \
  analysistemplate,analysisrun,job \
  -n bluegreen-demo
```

## Complete Demo Flow

```text
                Git = BLUE
                    |
                    v
             deploy-demo.sh
                    |
                    v
          BLUE becomes stable
                    |
                    v
       active Service -> BLUE
                    |
                    v
           switch-green.sh
                    |
                    v
        Git changes BLUE -> GREEN
                    |
                    v
               git push
                    |
                    v
               Argo CD
                    |
                    v
       GREEN ReplicaSet created
                    |
                    v
       preview Service -> GREEN
                    |
                    v
           GREEN becomes Ready
                    |
                    v
        pre-promotion AnalysisRun
                    |
             +------+------+
             |             |
           fail          success
             |             |
             v             v
           abort       manual gate
             |             |
             |             v
             |         promote
             |             |
             |             v
             |      active -> GREEN
             |             |
             |             v
             |        wait 30 sec
             |             |
             |             v
             |       BLUE scales down
             |
             v
     BLUE remains active
```

## Key Point

```text
Argo CD:
    delivers desired state from Git

Argo Rollouts:
    controls BLUE/GREEN transition and analysis

OpenShift Routes:
    remain stable ingress endpoints
```

The production Route is never manually repointed from BLUE to GREEN.

Argo Rollouts performs the switch underneath the stable production Route by changing the active Service's `rollouts-pod-template-hash`.
