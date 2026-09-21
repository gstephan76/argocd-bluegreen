# OpenShift GitOps + Argo Rollouts Canary Example

This example complements the repository's blue/green demo with a basic **canary Rollout managed by Argo CD**.

## Flow

```text
BLUE stable
   |
Git changes image to YELLOW
   |
Argo CD sync
   |
20% canary
   |
manual pause
   |
promote
   |
40% -> wait 20s
   |
60% -> wait 20s
   |
80% -> wait 20s
   |
100% YELLOW stable
```

## Important traffic-routing note

This example has no Service Mesh or dedicated traffic router. `setWeight` is therefore implemented by scaling the stable and canary ReplicaSets to approximate the requested weight.

With five replicas:

```text
20% -> 1 YELLOW + 4 BLUE
40% -> 2 YELLOW + 3 BLUE
60% -> 3 YELLOW + 2 BLUE
80% -> 4 YELLOW + 1 BLUE
```

The OpenShift Route points to one Kubernetes Service selecting all Rollout pods. This demonstrates the Rollout state machine, but is not precise L7 traffic shaping.

## Deploy

```bash
cd ~/Documents/POCs/ArgoCD
bash scripts/deploy-canary-demo.sh
```

Verify:

```bash
oc get applications.argoproj.io rollouts-canary-demo -n openshift-gitops
oc argo rollouts get rollout rollouts-canary-demo -n rollouts-canary-demo
```

## Start BLUE -> YELLOW

```bash
bash scripts/start-canary-yellow.sh
```

Watch:

```bash
oc argo rollouts get rollout rollouts-canary-demo -n rollouts-canary-demo --watch
```

At the first step the rollout pauses at approximately 20% YELLOW.

## Promote

```bash
oc argo rollouts promote rollouts-canary-demo -n rollouts-canary-demo
```

The remaining 40%, 60%, and 80% steps advance automatically after 20-second pauses.

## Abort

```bash
oc argo rollouts abort rollouts-canary-demo -n rollouts-canary-demo
```

After an abort, revert the YELLOW desired-state commit in Git because Argo CD still declares YELLOW as desired.

## Inspect

```bash
oc get rs,pod -n rollouts-canary-demo -l app=rollouts-canary-demo -o wide
oc get svc,route -n rollouts-canary-demo
```

## Relationship to the blue/green demo

```text
Blue/green:
  active + preview Services
  0%/100% cutover
  pre-promotion AnalysisRun

Basic canary:
  one Service
  stable + canary ReplicaSets
  progressive replica-based exposure
```

For precise traffic percentages, extend this example with OpenShift Service Mesh / Istio traffic routing.
