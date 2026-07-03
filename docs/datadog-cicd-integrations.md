# Datadog integrations for the CI/CD stack (ArgoCD, Argo Rollouts, Argo Workflows)

This repo already runs **ArgoCD** and **Argo Rollouts** (see
[`argocd/install-notes.md`](../argocd/install-notes.md)). **Argo Workflows is not
part of this stack** - it's covered below only as reference for anyone who adds it to
their own pipeline.

All three integrations below are Datadog Agent **checks** (not separate Datadog
products) - they're bundled into the Agent binary from a given version onward and
turned on via Kubernetes Autodiscovery pod annotations, the same mechanism already
used elsewhere in this repo (see `ad.datadoghq.com/discounts.logs` on
`rollouts/discounts-rollout.yaml`).

## Sources

- [Container-native CI/CD integrations blog post](https://www.datadoghq.com/blog/container-native-ci-cd-integrations/)
- [ArgoCD integration docs](https://docs.datadoghq.com/integrations/argocd/)
- [Argo Rollouts integration docs](https://docs.datadoghq.com/integrations/argo-rollouts/)
- [Argo Workflows integration docs](https://docs.datadoghq.com/integrations/argo-workflows/)
- [Cluster Checks docs](https://docs.datadoghq.com/containers/cluster_agent/clusterchecks/) (background on why `clusterChecks.enabled: true` matters here)

## 1. ArgoCD

**What it provides:** an Agent check (minimum Agent 7.41.0, OpenMetrics-based, needs
Python 3 - not a concern with the containerized Agent image) that scrapes
Prometheus-formatted metrics from ArgoCD's three components - the **Application
Controller**, **API Server**, and **Repo Server**. Per the blog post, this enables
"monitor[ing] metrics from ArgoCD and keep[ing] Kubernetes clusters up to date with
their latest manifest files," plus an out-of-the-box dashboard "surfac[ing] alerts
from pre-configured monitors for key ArgoCD metrics to notify you of any sync
issues." Collected metrics include application sync counts/duration
(`argocd.app_controller.app.sync.*`), app health/sync status
(`argocd.app_controller.app.info`), and orphaned-resource counts
(`argocd.app_controller.app.orphaned_resources.count`), among many Go-runtime/process
metrics per component (see the [full metric list](https://docs.datadoghq.com/integrations/argocd/)).

**Applicable to this repo?** Yes - ArgoCD is already installed per
`argocd/install-notes.md` step 1, from the upstream manifest
(`https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`).
That manifest is not vendored into this repo, so the integration isn't wired in by
default; enabling it means annotating the already-running ArgoCD pods (below).

**Setup on this repo's cluster:** the Datadog Operator agent
(`k8s-manifests/datadog/datadog-agent.yaml`) already has
`features.clusterChecks.enabled: true`, so once the annotations below exist on the
ArgoCD pods, the Cluster Agent dispatches these as cluster checks automatically (one
check per component cluster-wide, not duplicated per node) - see
[Cluster Checks](https://docs.datadoghq.com/containers/cluster_agent/clusterchecks/)
for how that dispatch works.

Since the ArgoCD Deployments/StatefulSet are created by the upstream install
manifest (not owned by this repo's `k8s-manifests/`), add the annotations with a
`kubectl patch` after step 1 of `argocd/install-notes.md` (exact annotation payloads
and endpoint ports are copied verbatim from the
[ArgoCD integration docs](https://docs.datadoghq.com/integrations/argocd/)):

```bash
# Application Controller (StatefulSet, metrics on :8082)
kubectl -n argocd patch statefulset argocd-application-controller --type merge -p '
spec:
  template:
    metadata:
      annotations:
        ad.datadoghq.com/argocd-application-controller.checks: |
          {"argocd": {"init_config": {}, "instances": [{"app_controller_endpoint": "http://%%host%%:8082/metrics"}]}}
'

# API Server (Deployment, metrics on :8083)
kubectl -n argocd patch deployment argocd-server --type merge -p '
spec:
  template:
    metadata:
      annotations:
        ad.datadoghq.com/argocd-server.checks: |
          {"argocd": {"init_config": {}, "instances": [{"api_server_endpoint": "http://%%host%%:8083/metrics"}]}}
'

# Repo Server (Deployment, metrics on :8084)
kubectl -n argocd patch deployment argocd-repo-server --type merge -p '
spec:
  template:
    metadata:
      annotations:
        ad.datadoghq.com/argocd-repo-server.checks: |
          {"argocd": {"init_config": {}, "instances": [{"repo_server_endpoint": "http://%%host%%:8084/metrics"}]}}
'
```

> **Not independently verified in this session:** the container names above
> (`argocd-application-controller`, `argocd-server`, `argocd-repo-server`) match the
> annotation keys shown in Datadog's own docs examples, but weren't cross-checked
> against the exact container names in the current `stable` ArgoCD install manifest on
> the live cluster. Before relying on this for a live demo, run
> `kubectl -n argocd get pod <pod-name> -o jsonpath='{.spec.containers[*].name}'` to
> confirm the container name matches the annotation key (the annotation is keyed as
> `ad.datadoghq.com/<container-name>.checks`), and adjust if the upstream manifest has
> renamed a container since these docs were written.

## 2. Argo Rollouts

**What it provides:** an Agent check (minimum Agent 7.53.0, OpenMetrics-based, built
into the Agent - no separate install) scraping the Argo Rollouts controller's
Prometheus metrics on port `8090`. Per the blog post, this lets you "track the
progress of...ongoing rollouts to avoid prolonged downtimes," "monitor analysis and
experiment telemetry," and "investigate scaling behavior and resource utilization...
with replica counts and reconciliation data." Metrics directly relevant to **this
repo's canary + Deployment Gate flow** include:

- `argo_rollouts.rollout.info` / `argo_rollouts.rollout.phase` - overall rollout state.
- `argo_rollouts.rollout.info.replicas.{available,desired,unavailable,updated}` -
  canary weight progress.
- `argo_rollouts.analysis.run.phase` / `argo_rollouts.analysis.run.metric.phase` -
  the Deployment Gate's `AnalysisRun` state (i.e. you could alert on this if a gate
  evaluation is stuck).
- `argo_rollouts.analysis.run.reconcile.error.count` - errors reconciling the
  `AnalysisRun` (distinct from the gate itself failing - this is Argo Rollouts having
  trouble running the check at all).

**Applicable to this repo?** Yes, directly - this is the controller that drives the
canary + Deployment Gate demo in `rollouts/discounts-rollout.yaml`. It's installed per
`argocd/install-notes.md` step 2, from the upstream Argo Rollouts release manifest
(`https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml`),
same caveat as ArgoCD: not vendored into this repo, so enable it with a patch.

**Setup on this repo's cluster:**

```bash
kubectl -n argo-rollouts patch deployment argo-rollouts --type merge -p '
spec:
  template:
    metadata:
      annotations:
        ad.datadoghq.com/argo-rollouts.checks: |
          {"argo_rollouts": {"init_config": {}, "instances": [{"openmetrics_endpoint": "http://%%host%%:8090/metrics"}]}}
'
```

Same container-name caveat as ArgoCD above applies: verify the container inside the
`argo-rollouts` Deployment is actually named `argo-rollouts` before relying on this
annotation key.

## 3. Argo Workflows (not currently used in this reference)

**What it provides (for context only):** an Agent check (minimum Agent 7.53.0,
OpenMetrics on port `9090` against the Workflow Controller) tracking "workflow
execution based on operation durations," resource allocation (Kubernetes request
counts, Go runtime stats), and workflow errors "cross-correlate[d] with error log
streams," per the [integration docs](https://docs.datadoghq.com/integrations/argo-workflows/)
and the [blog post](https://www.datadoghq.com/blog/container-native-ci-cd-integrations/).
It ships an out-of-the-box dashboard and recommended monitors automatically once
enabled.

**Applicable to this repo? No** - this reference implementation's pipeline is
ArgoCD (GitOps sync) + Argo Rollouts (canary/analysis) only. There is no Argo
Workflows controller in this stack, and nothing here should be read as implying one
is wired in.

**If you introduce Argo Workflows into your own pipeline**, the setup follows the
same Autodiscovery pattern as the two checks above - annotate the Workflow
Controller's pod template with:

```bash
kubectl -n argo patch deployment workflow-controller --type merge -p '
spec:
  template:
    metadata:
      annotations:
        ad.datadoghq.com/workflow-controller.checks: |
          {"argo_workflows": {"init_config": {}, "instances": [{"openmetrics_endpoint": "http://%%host%%:9090/metrics"}]}}
'
```

(Namespace/Deployment/container names above assume the default Argo Workflows
install layout - `namespace: argo`, Deployment `workflow-controller` - adjust to
match your actual install.)

## Log collection (all three)

All three integration docs also describe optional log collection from their
respective pods, gated behind the Agent's cluster-wide log collection feature
(already enabled here via
`k8s-manifests/datadog/datadog-agent.yaml`'s `features.logCollection.enabled: true`).
Each doc gives the same pattern: an Autodiscovery log-processing-rule annotation
(`{"source": "<argocd|argo_rollouts|argo_workflows>", "service": "<name>"}`) - see each
integration's own "Log collection" section linked above for the exact annotation key
per component, since it's the same annotation family as the metrics annotations above
but on the `<container>.logs` key instead of `<container>.checks`.
