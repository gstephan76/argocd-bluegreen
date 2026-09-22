# OpenShift GitOps + Argo Rollouts Canary Demo

This demo implements a Prometheus-gated Argo Rollouts canary on OpenShift GitOps.

The rollout advances automatically through 33%, 66%, and 100% only after each inline AnalysisRun succeeds. After the 100% HTTP-200 gate succeeds, the Rollout pauses for one explicit operator approval before the candidate ReplicaSet is declared stable.

No second OpenShift Route is created. The existing public Route remains the user-facing application Route.

## Rollout flow

Six replicas make the basic canary weights map cleanly to pod counts:

```text
33%  -> 2 canary + 4 stable
66%  -> 4 canary + 2 stable
100% -> 6 canary
```

The complete flow is:

```text
fresh canary revision
        |
        v
      33%
        |
  3 x HTTP 200
        |
        v
      66%
        |
  3 x HTTP 200
        |
        v
      100%
        |
  3 x HTTP 200
        |
        v
 FINAL MANUAL PAUSE
        |
 operator promotes
        |
        v
 candidate becomes STABLE
```

If any inline analysis fails, the rollout does not progress to the next weight.

## What is being tested

The existing public Route is unchanged and is useful for demonstrating the application from a browser or with `curl`.

The promotion gate itself deliberately probes the canary-only Service:

```text
http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color
```

Argo Rollouts owns that Service selector and points it only at the current canary ReplicaSet. Stable pods therefore cannot hide a broken candidate.

Blackbox Exporter is scraped by OpenShift user-workload Prometheus. The AnalysisTemplate requires three successful measurements for both:

```text
probe_http_status_code == 200
probe_success == 1
```

With `failureLimit: 1`, a failed measurement causes the analysis to fail.

## 1. Deploy or reconcile the demo

From the repository root:

```bash
cd ~/Documents/POCs/ArgoCD

bash scripts/deploy-canary-demo.sh
```

The deploy script ensures user-workload monitoring is available, applies the Rollouts bootstrap and Prometheus access resources, reconciles the Argo CD Application, and waits for the Blackbox Exporter.

Verify the main resources:

```bash
oc get rollout,analysistemplate,analysisrun   -n rollouts-canary-demo

oc get servicemonitor,svc,route   -n rollouts-canary-demo
```

## 2. Open or curl the application

Get the existing public Route:

```bash
HOST="$(oc get route rollouts-canary-demo   -n rollouts-canary-demo   -o jsonpath='{.spec.host}')"

echo "https://${HOST}"
```

Check the public application:

```bash
curl -sk   -o /dev/null   -w 'HTTP %{http_code}\n'   "https://${HOST}/"
```

A normal application response is:

```text
HTTP 200
```

This public Route check is useful for the demo, but it is not the promotion signal because the normal Service can include both stable and canary pods while a rollout is in progress.

## 3. Start a fresh canary revision

Run:

```bash
bash scripts/start-canary-yellow.sh
```

The script changes the Git-managed `demo-rollout-revision` pod-template annotation, commits and pushes the change, waits for the exact Argo CD revision, and then watches the rollout through:

```text
33% -> HTTP-200 analysis
66% -> HTTP-200 analysis
100% -> HTTP-200 analysis
final pause
```

No manual action is required between 33%, 66%, and 100%.

Watch the rollout in another terminal if desired:

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo   --watch
```

Watch the AnalysisRuns:

```bash
watch -n 2 '
oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp
'
```

## 4. Verify the canary HTTP probe directly

The Blackbox Exporter automatically generates the HTTP requests used by Prometheus. You do not need to refresh the browser to satisfy the gate.

To inspect exactly what Blackbox sees, port-forward it:

```bash
oc port-forward   -n rollouts-canary-demo   svc/rollouts-canary-blackbox   9115:9115
```

In another terminal:

```bash
curl -sS --get   'http://127.0.0.1:9115/probe'   --data-urlencode 'module=http_200'   --data-urlencode 'target=http://rollouts-canary-demo-canary.rollouts-canary-demo.svc.cluster.local/color'   | rg '^(probe_http_status_code|probe_success) '
```

Expected:

```text
probe_http_status_code 200
probe_success 1
```

A completed analysis should contain three successful `200` measurements and three successful `probe_success=1` measurements.

## 5. Final manual promotion to stable

After all three weight stages have passed their Prometheus gates, the Rollout intentionally stops at the final pause.

At that point the candidate is at 100% exposure, but it is not yet the stable ReplicaSet.

Promote it with:

```bash
bash scripts/promote-canary-stable.sh
```

The direct Argo Rollouts equivalent is:

```bash
oc argo rollouts promote rollouts-canary-demo   -n rollouts-canary-demo
```

Do not use `--full` for this demo.

The helper waits until:

```text
phase == Healthy
stableRS == currentPodHash
```

and then prints the final Rollout state.

## 6. Final verification

```bash
oc argo rollouts get rollout rollouts-canary-demo   -n rollouts-canary-demo

oc get analysisrun   -n rollouts-canary-demo   --sort-by=.metadata.creationTimestamp
```

A successful demo ends with the new ReplicaSet marked stable and successful AnalysisRuns for the 33%, 66%, and 100% HTTP-200 gates.
