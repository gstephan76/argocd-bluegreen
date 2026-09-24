# Argo CD + Argo Rollouts Blue/Green Demo on OpenShift

This demo uses **Argo CD** for GitOps desired state and **Argo Rollouts** for the runtime Blue/Green lifecycle.

The candidate is validated twice:

```text
GREEN preview
    |
    | prePromotionAnalysis
    | 3 HTTP smoke checks
    v
manual promotion gate
    |
    v
ACTIVE Service -> GREEN
    |
    | postPromotionAnalysis
    | 5 HTTP smoke checks
    v
GREEN becomes STABLE
```

If the pre-promotion analysis fails, production remains on the previous active ReplicaSet. If the post-promotion analysis fails or errors, Argo Rollouts aborts and restores the active Service to the previous stable ReplicaSet.

## Architecture

The OpenShift Routes stay fixed. Argo Rollouts changes the hash selector of the Services:

```text
Production Route                    Preview Route
      |                                  |
      v                                  v
bluegreen-demo-active            bluegreen-demo-preview
      |                                  |
      v                                  v
ACTIVE ReplicaSet                 PREVIEW ReplicaSet
```

`argocd/application.yaml` ignores only the Rollouts-owned `rollouts-pod-template-hash` key on the active and preview Services and enables `RespectIgnoreDifferences=true`. Argo CD therefore continues to own the rest of each Service without fighting the Rollouts controller.

## Analysis behavior

### Pre-promotion analysis

`bluegreen-demo/analysis-template.yaml` performs three HTTP checks against the
preview Service's `/color` endpoint and requires the response identity to match
the expected candidate color. For the GREEN scenario the expected body is
`"green"`.

```text
http://bluegreen-demo-preview.bluegreen-demo.svc.cluster.local/color
```

The active Service is not switched until this AnalysisRun succeeds, so the gate
proves both availability and candidate identity.

### Post-promotion analysis

`bluegreen-demo/post-analysis-template.yaml` performs five equivalent checks
through the active Service after cutover:

```text
http://bluegreen-demo-active.bluegreen-demo.svc.cluster.local/color
```

The post-analysis Job has a 60-second deadline because five checks can consume
up to 35 seconds from curl timeouts and sleeps alone. Only after this AnalysisRun
succeeds is the candidate marked stable.

`scaleDownDelaySeconds` is intentionally omitted. With post-promotion analysis configured, the previous stable ReplicaSet is retained until that analysis completes, so it remains available as the rollback target during post-promotion validation.

## Recommended scripted demo

### Live session: scripts and terminals

Use three terminals for the clearest presentation.

**Terminal 1 — operator/control**

Run the Blue/Green workflow here, in this exact order. Wait for each script to
finish successfully before starting the next one:

```bash
cd ~/Documents/POCs/ArgoCD

bash scripts/deploy-demo.sh
bash scripts/prepare-blue.sh
bash scripts/switch-green.sh --preview-only

# At this point:
#   Production Route -> BLUE
#   Preview Route    -> GREEN
# Inspect both URLs before the cutover.

bash scripts/promote-bluegreen.sh
```

**Terminal 2 — live Rollout view**

Start this before `switch-green.sh --preview-only` and leave it running:

```bash
cd ~/Documents/POCs/ArgoCD

oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo \
  --watch
```

**Terminal 3 — analysis and workload details**

This terminal is optional but useful while explaining the pre- and
post-promotion checks:

```bash
watch -n 2 '
oc get analysisrun,job,rs,pod \
  -n bluegreen-demo
'
```

The intended session is:

```text
Terminal 1                         Terminal 2                  Terminal 3
----------                         ----------                  ----------
deploy-demo.sh                     Rollout status              analysis/jobs
prepare-blue.sh                    BLUE stable                 BLUE analyses
switch-green.sh --preview-only     GREEN preview / Paused      pre-analysis
inspect active + preview Routes
promote-bluegreen.sh               GREEN active / stable       post-analysis
```

Do not start `switch-green.sh --preview-only` until `prepare-blue.sh` has
returned successfully. Do not run `promote-bluegreen.sh` until the
preview-only script has returned after a successful pre-promotion analysis.

Run from the repository root:

```bash
cd ~/Documents/POCs/ArgoCD
```

### 1. Reconcile the demo

```bash
bash scripts/deploy-demo.sh
```

The script validates Git state, applies the Rollouts bootstrap, reconciles the
Argo CD Application to the exact Git commit, waits for both AnalysisTemplates,
and prints the active and preview URLs. Its contract is platform/GitOps
reconciliation only; it does **not** claim that BLUE is the canonical stable
presentation baseline.

### 2. Ensure a clean BLUE baseline

The repository may already request GREEN after an earlier demo. This command is
the trusted recovery operation and is safe to run either way:

```bash
bash scripts/prepare-blue.sh
```

`prepare-blue.sh` restores the exact declarative BLUE state (`:blue`,
`baseline-blue`, and BLUE analysis identity), waits for Argo CD to sync that
exact Git revision, then uses `oc argo rollouts promote --full` only after the
live Rollout is proven to be that canonical desired state. Recovery therefore
does not depend on the smoke-test mechanism being healthy. It returns only when
BLUE is `Healthy` and active/preview/stable/current all converge on the same
ReplicaSet, then reruns platform/GitOps reconciliation.

### 3. Create and validate GREEN without production cutover

```bash
bash scripts/switch-green.sh --preview-only
```

The flow is:

```text
settled canonical BLUE
        |
        v
Git BLUE -> GREEN + fresh unique revision marker
        |
        v
Argo CD exact-revision sync
        |
        v
GREEN preview == current desired ReplicaSet
        |
        v
pre-promotion AnalysisRun
        |
        v
3 HTTP + /color identity checks succeed
        |
        v
PAUSED before production cutover
```

Every GREEN attempt gets a new `demo-rollout-revision` annotation, so a retry
cannot accidentally reuse the AnalysisRun/ReplicaSet state of a previous failed
attempt. A fresh GREEN attempt is accepted only from the settled canonical BLUE
baseline; after any failed attempt, run `prepare-blue.sh` first.

At this point:

```text
Production Route -> BLUE
Preview Route    -> GREEN
```

Open both URLs printed by the script and compare them.

### 4. Manually promote the validated preview

```bash
bash scripts/promote-bluegreen.sh
```

The helper binds promotion to the exact Git/Argo CD revision and live
candidate before changing production traffic. It requires a clean synchronized
Git tree, `ACTIVE == stableRS`, `PREVIEW == currentPodHash`, a GREEN preview,
successful pre-analysis, and the manual `Paused` gate. It then promotes exactly
one step, waits for the active Service switch and post-promotion AnalysisRun,
and proves that GREEN becomes active, preview, current, and stable. If
post-analysis fails, the script separately verifies that ACTIVE actually
returns to the previous stable ReplicaSet before reporting rollback success.

Expected flow:

```text
manual promote
     |
     v
ACTIVE Service -> GREEN
     |
     v
post-promotion AnalysisRun
     |
     +-- failure/error --> automatic abort and ACTIVE -> previous BLUE
     |
     +-- success -------> GREEN becomes STABLE
```

For a one-command GREEN switch after BLUE is stable, this remains available:

```bash
bash scripts/switch-green.sh
```

That performs the preview/pre-analysis phase and then delegates promotion and post-analysis validation to `promote-bluegreen.sh`.

## Manual demo without helper scripts

The sequence below is a low-level educational equivalent for the normal
Blue/Green transition. The scripted `prepare-blue.sh` recovery is intentionally
stronger: it is a trusted recovery operation that verifies the canonical BLUE
Git/live identity and uses `promote --full` to bypass analysis during recovery.
Do not use an ordinary analyzed BLUE rollout as a substitute when recovering
from broken analysis infrastructure.

### 1. Verify access and required APIs

```bash
oc whoami
oc argo rollouts version

oc get crd applications.argoproj.io
oc get crd argocds.argoproj.io
oc get crd rollouts.argoproj.io
oc get crd rolloutmanagers.argoproj.io
oc get crd analysistemplates.argoproj.io
oc get crd analysisruns.argoproj.io
```

### 2. Apply bootstrap and the Argo CD Application

```bash
oc apply -k bootstrap

oc apply \
  -f argocd/application.yaml

oc annotate applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

Inspect Argo CD synchronization:

```bash
oc get applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status} revision={.status.sync.revision}{"\n"}'
```

### 3. Verify both AnalysisTemplates

```bash
oc get analysistemplate \
  bluegreen-demo-smoke-test \
  bluegreen-demo-post-smoke-test \
  -n bluegreen-demo
```

### 4. Verify active and preview Services/Routes

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo

oc get route \
  bluegreen-demo \
  bluegreen-demo-preview \
  -n bluegreen-demo
```

Display the current Rollouts hash selectors:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

### 5. Establish BLUE as the baseline if necessary

The trusted scripted recovery is preferred:

```bash
bash scripts/prepare-blue.sh
```

For an educational manual equivalent, restore **all three pieces** of canonical
desired state: image, revision marker, and both analysis identities:

```bash
sed -i -E \
  -e 's#image: argoproj/rollouts-demo:(blue|green)#image: argoproj/rollouts-demo:blue#' \
  -e 's#demo-rollout-revision: ".*"#demo-rollout-revision: "baseline-blue"#' \
  bluegreen-demo/rollout.yaml

sed -i -E \
  '/- name: expected-color/{n;s#value: (blue|green)#value: blue#;}' \
  bluegreen-demo/rollout.yaml

git add bluegreen-demo/rollout.yaml
git diff --cached --check
git commit -m "Restore canonical blue baseline"
git push origin main
```

After Argo CD has synced that exact revision, verify the live Rollout itself
declares the canonical BLUE image and marker before using trusted full
promotion:

```bash
REV="$(git rev-parse HEAD)"

oc annotate applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  argocd.argoproj.io/refresh=hard \
  --overwrite

oc get applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} revision={.status.sync.revision}{"\n"}'

oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='image={.spec.template.spec.containers[0].image} marker={.spec.template.metadata.annotations.demo-rollout-revision}{"\n"}'
```

Only when Argo CD reports `Synced` at `$REV` and the live output is
`:blue` / `baseline-blue`, trusted recovery may bypass analysis:

```bash
oc argo rollouts promote bluegreen-demo -n bluegreen-demo --full
```

Wait for BLUE to become `Healthy` with active, preview, current, and stable
hashes converged before continuing.

### 6. Commit GREEN desired state

Create a fresh marker and change the image **and both expected-color args**:

```bash
TRIGGER="bluegreen-green-$(date -u +%Y%m%dT%H%M%SZ)-$$"

sed -i -E \
  's#argoproj/rollouts-demo:blue#argoproj/rollouts-demo:green#' \
  bluegreen-demo/rollout.yaml

sed -i -E \
  "s#demo-rollout-revision: \".*\"#demo-rollout-revision: \"${TRIGGER}\"#" \
  bluegreen-demo/rollout.yaml

sed -i -E \
  '/- name: expected-color/{n;s#value: blue#value: green#;}' \
  bluegreen-demo/rollout.yaml

git add bluegreen-demo/rollout.yaml
git diff --cached --check
git commit -m "Deploy fresh green preview"
git push origin main
```

Record the exact Git revision:

```bash
REV="$(git rev-parse HEAD)"
echo "$REV"
```

Force Argo CD to refresh:

```bash
oc annotate applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  argocd.argoproj.io/refresh=hard \
  --overwrite
```

Check until Argo CD reports the same revision:

```bash
oc get applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  -o jsonpath='sync={.status.sync.status} revision={.status.sync.revision}{"\n"}'
```

The reported revision must equal `$REV`.

### 7. Watch GREEN preview and pre-promotion analysis

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo \
  --watch
```

In another terminal:

```bash
watch -n 2 '
oc get analysisrun,job \
  -n bluegreen-demo
'
```

Get the current pre-promotion AnalysisRun:

```bash
PRE_ANALYSIS="$(oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='{.status.blueGreen.prePromotionAnalysisRunStatus.name}')"

echo "$PRE_ANALYSIS"

oc get analysisrun "$PRE_ANALYSIS" \
  -n bluegreen-demo \
  -o yaml
```

View the three preview smoke checks:

```bash
oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-analysis \
  --tail=-1
```

Before promotion, active and preview hashes must differ:

```bash
oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

### 8. Test both OpenShift Routes

```bash
ACTIVE_HOST="$(oc get route bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='{.spec.host}')"

PREVIEW_HOST="$(oc get route bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{.spec.host}')"

echo "ACTIVE : https://${ACTIVE_HOST}"
echo "PREVIEW: https://${PREVIEW_HOST}"
```

Optional HTTP checks:

```bash
curl -sk \
  -o /dev/null \
  -w 'ACTIVE HTTP %{http_code}\n' \
  "https://${ACTIVE_HOST}/"

curl -sk \
  -o /dev/null \
  -w 'PREVIEW HTTP %{http_code}\n' \
  "https://${PREVIEW_HOST}/"
```

### 9. Promote GREEN manually

Only after the pre-promotion AnalysisRun is `Successful`:

```bash
oc argo rollouts promote bluegreen-demo \
  -n bluegreen-demo
```

The production Route itself does not change. Argo Rollouts changes the selector of `bluegreen-demo-active` to the GREEN hash.

Watch the Rollout:

```bash
oc argo rollouts get rollout bluegreen-demo \
  -n bluegreen-demo \
  --watch
```

### 10. Inspect post-promotion analysis

Get the post-promotion AnalysisRun:

```bash
POST_ANALYSIS="$(oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='{.status.blueGreen.postPromotionAnalysisRunStatus.name}')"

echo "$POST_ANALYSIS"
```

Inspect it:

```bash
oc get analysisrun "$POST_ANALYSIS" \
  -n bluegreen-demo \
  -o yaml
```

View the five production smoke checks:

```bash
oc logs \
  -n bluegreen-demo \
  -l app=bluegreen-demo-post-analysis \
  --tail=-1
```

If the post analysis fails or errors, Argo Rollouts aborts and restores the active Service to the previous stable ReplicaSet.

### 11. Verify final stable state

```bash
oc get rollout bluegreen-demo \
  -n bluegreen-demo \
  -o jsonpath='phase={.status.phase} stableRS={.status.stableRS}{"\n"}'

oc get svc \
  bluegreen-demo-active \
  bluegreen-demo-preview \
  -n bluegreen-demo \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.selector.rollouts-pod-template-hash}{"\n"}{end}'
```

A completed rollout is `Healthy`, and the active/preview Service selectors point to the new stable GREEN ReplicaSet.

## Failure behavior

Pre-promotion failure:

```text
GREEN preview
   |
pre-analysis fails
   |
Rollout aborts
   |
ACTIVE remains BLUE
```

Post-promotion failure:

```text
ACTIVE switches to GREEN
   |
post-analysis fails/errors
   |
Rollout aborts
   |
ACTIVE switches back to previous stable BLUE
```

After a failed candidate, run:

```bash
bash scripts/prepare-blue.sh
```

before starting another GREEN attempt. `switch-green.sh` deliberately refuses
to create a new candidate unless Git, Argo CD, and the live Rollout prove the
settled canonical BLUE baseline.

## Useful diagnostics

```bash
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

oc get svc,route \
  -n bluegreen-demo

oc get applications.argoproj.io bluegreen-demo \
  -n openshift-gitops \
  -o yaml
```

## Quick reference

Recommended live-demo sequence:

```bash
bash scripts/deploy-demo.sh
bash scripts/prepare-blue.sh
bash scripts/switch-green.sh --preview-only
bash scripts/promote-bluegreen.sh
```

One-command GREEN switch after BLUE is stable:

```bash
bash scripts/switch-green.sh
```

Timeout overrides:

```bash
TIMEOUT_SECONDS=600 bash scripts/deploy-demo.sh
TIMEOUT_SECONDS=600 bash scripts/prepare-blue.sh
TIMEOUT_SECONDS=600 bash scripts/switch-green.sh --preview-only
TIMEOUT_SECONDS=600 bash scripts/promote-bluegreen.sh
```
