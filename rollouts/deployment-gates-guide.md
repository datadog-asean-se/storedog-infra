# Setting up the Deployment Gate policy

This document walks through the Datadog **Deployment Gate** used by
`rollouts/discounts-rollout.yaml`, why it's implemented the way it is, and how to
adapt it for your own service.

> ## ⚠️ Known gap: gate FAIL→rollback has not been reproduced live
>
> The PASS→promote path is fully proven live (real evaluation IDs, real API
> confirmation, real promotion to `setWeight: 100`). The **FAIL→rollback** path is
> not: across 8 live attempts against this demo's Datadog org, the gate **passed
> every time**, including the most recent attempt with airtight evidence of a real,
> fully-instrumented regression (see below). This is no longer believed to be an
> APM sampling/ingestion problem - that hypothesis was directly tested and ruled
> out. What remains open is a genuine question about Watchdog Faulty Deployment
> Detection's sensitivity or confidence requirements for this traffic pattern.
>
> **What was tested and ruled out (this round):**
> - **Org-level retention filters** (`GET /api/v2/apm/config/retention-filters`):
>   an "Error Default" filter (`status:error`, `rate: 1`) is already enabled
>   org-wide - error spans that reach this stage should already be retained at
>   100%. Not the blocker.
> - **Client-side trace sampling**: added `DD_TRACE_SAMPLE_RATE=1.0` to the
>   `discounts` Rollout's pod env (see `rollouts/discounts-rollout.yaml`) to force
>   100% local sampling, ruling out Agent-side head-based sampling (default target
>   ~10 traces/sec/Agent) as a factor at this demo's traffic volume.
> - **The actual root cause of every prior attempt's near-zero error-span counts**:
>   `buggy-image/sitecustomize.py` used to inject the fault by monkeypatching
>   `Flask.wsgi_app` directly and calling `start_response()` itself - bypassing
>   Flask's (and therefore ddtrace's Flask integration's) normal request/exception
>   dispatch entirely for the faulty code path. Those 500s were real HTTP
>   responses but were **never recorded as APM errors at all**. Fixed by
>   rewriting the fault injection as a Flask `before_request` hook +
>   `flask.abort(500)`, which flows through Flask's normal exception handling and
>   is fully visible to ddtrace.
>
> **Result after the fix - error spans now show up correctly**, with dramatically
> more volume and clear `status:error` tagging (verified via the Datadog Spans
> Analytics API immediately after a fresh live attempt):
>
> | | Requests | Errors | Error rate |
> |---|---|---|---|
> | Stable baseline (`1.0.0`) | 318 | 0 | 0% |
> | Buggy canary (this attempt) | 328 | 228 | ~70% |
>
> That is a dramatic, unambiguous, properly-instrumented regression by any
> reasonable statistical standard, evaluated over Datadog's own recommended 900s
> window - and the gate **still returned `pass`**. Confirmed via a direct
> `GET /api/v2/deployments/gates/evaluation/<id>` API call (not just the
> `datadog-ci` CLI's own report) for evaluation ID `bc3c355d-f4b6-47c6-b9ae-5728d766584c`
> (version `bad-20260705112212`, `store-discounts`, org `nuttee.datadoghq.com`) -
> use this ID to look the evaluation up directly in the Deployment Gates
> Evaluations page in the Datadog UI.
>
> **Before presenting the FAIL path live, check:**
> - Whether `faulty_deployment_detection` needs more historical data for the
>   *previous* version specifically (each demo run mints a brand-new unique
>   `version` string with only one prior deployment's worth of history - it's
>   possible Watchdog wants a longer-established baseline across multiple
>   deployments of the same service before it trusts a comparison, independent of
>   how much data the *new* version has).
> - The actual Deployment Gates Evaluations page in the Datadog UI for the
>   evaluation ID above (not accessible via this session's CLI-only access) -
>   it may show a specific reason/confidence score the API's `pass`/`fail` summary
>   doesn't surface.
> - Consider asking Datadog support directly, referencing the evaluation ID and
>   the before/after error-span data above - this now looks like a question about
>   Faulty Deployment Detection's detection logic/thresholds for this specific
>   service and traffic shape, not a problem with this repo's gate configuration
>   or instrumentation (both independently verified correct).
>
> If you resolve this, please update this note with what fixed it.

## What a Deployment Gate is

A Deployment Gate is a Datadog check that runs *during* a deployment and returns
`pass` or `fail`. Argo Rollouts treats the gate as an `AnalysisRun` step in a canary:
if the gate fails, the canary is aborted and rolled back; if it passes, the rollout
proceeds to `setWeight: 100`.

A Gate has two evaluation modes ([docs](https://docs.datadoghq.com/deployment_gates/setup/)):

| | JIT (used in this repo) | Preconfigured |
|---|---|---|
| Where rules live | Inline, in your deployment config (the ConfigMap below) | In the Datadog UI/API/Terraform |
| Setup needed in Datadog | **None** | Create the gate + rules ahead of time |
| Best fit | Rules-as-code, per-deployment flexibility | Centrally-managed policy across teams |

This repo uses **JIT** on purpose: the whole point of the demo is that an SE (or any
engineer) can clone this repo and run it with zero prior configuration inside the
target Datadog org - no gate has to exist in the UI first. This is the "newly
available JIT inline configuration" approach Datadog shipped for Deployment Gates: you
commit the rules as code (in the ConfigMap below) and Datadog evaluates them
per-deployment, with no Datadog-side object required beforehand.

Deployment Gates are a Preview feature on most Datadog sites (per the
[setup docs](https://docs.datadoghq.com/deployment_gates/setup/)), which normally
means requesting Preview access before a gate evaluation will work. **For this
demo's Datadog org, Preview access has been confirmed enabled** by the demo owner -
this is not something that still needs checking before presenting. If you're
re-running this demo against a different org, confirm Preview access there first.

## The ConfigMap + `ClusterAnalysisTemplate` pattern used here

Datadog's own Argo Rollouts integration guide ([JIT setup docs, Argo Rollouts
tab](https://docs.datadoghq.com/deployment_gates/setup/jit/?tab=argorollouts)) ships
the gate as a **`ClusterAnalysisTemplate`** (not a namespace-scoped
`AnalysisTemplate`), specifically so one gate policy object can be referenced by any
`Rollout`, in any namespace, without redefining it per-namespace. This repo follows
that pattern in
[`deployment-gate-cluster-analysis-template.yaml`](deployment-gate-cluster-analysis-template.yaml):

```yaml
# 1. The inline JIT rules, as a namespace-scoped ConfigMap (mounted into the Job below).
apiVersion: v1
kind: ConfigMap
metadata:
  name: datadog-gate-config
  namespace: storedog          # <- must match the Rollout's namespace (see note below)
data:
  gate-config.json: |
    {
      "dryRun": false,
      "rules": [
        {
          "type": "faulty_deployment_detection",
          "name": "APM Faulty Deployment Detection - discounts",
          "options": { "duration": 300 }
        }
      ]
    }
---
# 2. The cluster-scoped analysis template - no `namespace:` field.
apiVersion: argoproj.io/v1alpha1
kind: ClusterAnalysisTemplate
metadata:
  name: datadog-deployment-gate
spec:
  args:
    - name: service
    - name: env
    - name: version            # required for faulty_deployment_detection rules
  metrics:
    - name: datadog-deployment-gate
      failureLimit: 0          # any failure of the single Job = gate failure
      provider:
        job:
          spec:
            backoffLimit: 0    # never retry a failed gate evaluation
            template:
              spec:
                containers:
                  - name: datadog-ci
                    image: datadog/ci:latest
                    args:
                      - >
                        datadog-ci deployment gate
                        --service "{{args.service}}" --env "{{args.env}}"
                        --version "{{args.version}}" --config /config/gate-config.json
                    volumeMounts:
                      - { name: gate-config, mountPath: /config }
                volumes:
                  - { name: gate-config, configMap: { name: datadog-gate-config } }
```

**Why cluster-scoped, but the ConfigMap/Secret stay namespaced:** only the *template*
object is cluster-scoped and reusable. The `AnalysisRun` it spawns - and the
Kubernetes `Job` that `AnalysisRun` creates - still run in the **Rollout's own
namespace** (`storedog` here). That's why `datadog-gate-config` and the
`datadog-ci-keys` secret both stay namespaced to `storedog`: that's where the Job
actually mounts them from.

**Referencing it from the Rollout requires `clusterScope: true`.** This is the part
that's easy to miss: a `Rollout`'s `analysis.templates[]` entry defaults to looking up
a namespace-scoped `AnalysisTemplate`. To point it at a `ClusterAnalysisTemplate`
instead, you must set `clusterScope: true` on that entry
([`rollouts/discounts-rollout.yaml`](discounts-rollout.yaml)):

```yaml
        - analysis:
            templates:
              - templateName: datadog-deployment-gate
                clusterScope: true   # <- required to resolve a ClusterAnalysisTemplate
            args:
              - name: service
                valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/service']" } }
              - name: env
                valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/env']" } }
              - name: version
                valueFrom: { fieldRef: { fieldPath: "metadata.labels['tags.datadoghq.com/version']" } }
```

This was verified against the live Argo Rollouts CRD (pulled from
`https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml`):
the `Rollout` CRD's `spec.strategy.canary.steps[].analysis.templates[]` schema
includes a `clusterScope: boolean` field, and a separate
`clusteranalysistemplates.argoproj.io` CRD exists alongside `analysistemplates.argoproj.io`,
confirming `ClusterAnalysisTemplate` is a distinct, current kind (not a typo/alias of
`AnalysisTemplate`).

## How `faulty_deployment_detection` works

Per the [JIT rule-types docs](https://docs.datadoghq.com/deployment_gates/setup/jit/?tab=argorollouts)
("APM Faulty Deployment Detection" tab):

- It uses Watchdog's APM Faulty Deployment Detection analysis to compare the newly
  deployed **`version`** against **previous versions of the same service**, looking
  for new error types and significant error-rate increases.
- It runs automatically for any APM-instrumented service - **no prior Datadog-side
  setup is required** (this is what makes it a good fit for JIT).
- `version` is a **required** argument for this rule type - that's why the Rollout
  passes it explicitly via `tags.datadoghq.com/version` (see
  `scripts/rollout-bad.sh` / `rollout-good.sh`, which bump this label + the `DD_VERSION`
  env var + the image tag together, so Faulty Deployment Detection sees each demo run
  as a genuinely new version).
- `options` fields for this rule type:
  - `duration` (optional): length of the analysis window in seconds. Datadog's
    general recommendation for production use is **at least 900s (15 minutes)**
    "for optimal analysis confidence"; the max is 7200s (2 hours). **This repo
    now uses `duration: 900`**, matching that recommendation.

    This repo originally shipped `duration: 300` on the theory that the injected
    fault (`buggy-image/`, ~25% error rate / +600ms latency) was severe enough to
    trip detection well inside a short window, and that trade-off was reviewed
    and signed off as acceptable for demo purposes. A live end-to-end test
    against a real Datadog org proved that assumption wrong in practice: at 300s
    and 25% canary weight, every attempt against the genuinely broken canary
    **passed** the gate. Root cause, confirmed via the Datadog Spans Analytics
    API: `store-discounts` is backed by Werkzeug's single-threaded development
    server and (independently of the injected fault) already has multi-second
    response times under any concurrent load, and the app's own discount-listing
    endpoint does what looks like an N+1 relationship query per row - so even
    modest traffic during a 300s window produced only a handful of samples
    against the canary, nowhere near enough for Watchdog to reach a confident
    verdict. Widening the window to 900s, combined with a patient, purely
    sequential load generator (`scripts/generate-discount-load.sh` - see its
    header comment for why sequential, not concurrent, matters here), gives
    enough elapsed time to accumulate a meaningful sample even against a slow
    backend. **For a real production gate against a normally-performant service,
    900s is a reasonable default; if your service is this slow, budget for an
    even longer window or fix the underlying performance issue first.**
  - `included_resources` (optional): if set, only these APM resources are analyzed.
  - `excluded_resources` (optional): APM resources to ignore (e.g. low-value or noisy
    endpoints like health checks), so they don't generate false positives/negatives.
    Not used in this demo config, but the syntax (per the docs' own example) is:

    ```json
    {
      "type": "faulty_deployment_detection",
      "name": "APM Faulty Deployment Detection",
      "options": {
        "duration": 900,
        "excluded_resources": ["GET /healthcheck"]
      }
    }
    ```

- The rule does **not** support services marked as `database` or `inferred service`.
- New errors / error-rate increases are detected at the APM **resource** level, and
  the rule is evaluated per additional primary tag value plus an aggregate (you can
  scope to a single primary tag via `primary_tag` in the request - not used here).

## How this maps to the Rollout's canary steps

```yaml
strategy:
  canary:
    steps:
      - setWeight: 25            # 1. shift 25% of traffic to the new version
      - pause: { duration: 60 }  #    let APM start seeing real traffic from it
      - analysis:                # 2. run the Deployment Gate (blocks until pass/fail)
          templates:
            - templateName: datadog-deployment-gate
              clusterScope: true
          args: [service, env, version]
      - setWeight: 100           # 3. only reached if the gate PASSED
```

If the gate's Job exits non-zero (gate `fail`, or the Datadog API call errors out),
the `AnalysisRun` reports `Failed`, and Argo Rollouts aborts the rollout and rolls the
`discounts` Deployment back to the last stable ReplicaSet automatically - no manual
intervention. If the Job exits `0` (gate `pass`), the canary proceeds to
`setWeight: 100`.

## This is genuinely "JIT" - no gate exists in the Datadog UI

To be explicit about the claim above: nothing in this repo creates a Deployment Gate
object via the Datadog UI, API, or Terraform ahead of time. The `configuration.rules`
JSON in the ConfigMap **is** the gate definition, submitted fresh on every
`datadog-ci deployment gate` invocation. This is exactly the "Just-In-Time" mode
described in the docs: "No gate needs to exist in Datadog ahead of time, which makes
JIT a good fit for rules-as-code and per-deployment flexibility." If you'd rather
manage this policy centrally in the Datadog UI/Terraform instead (e.g. so a platform
team owns it and app teams can't change it per-deployment), see
[Preconfigured Deployment Gates](https://docs.datadoghq.com/deployment_gates/setup/)
instead - that's a different mode, not covered by this repo.

## Onboarding tip: `dryRun`

If you're pointing this at a Datadog org/service pair you haven't gated before,
consider flipping `"dryRun": true` in the ConfigMap first. Per the docs'
[first-time onboarding recommendation](https://docs.datadoghq.com/deployment_gates/setup/jit/?tab=argorollouts):
a dry-run evaluation always returns `pass` to the caller (so it never blocks a real
deployment), while the *real* result is still recorded and visible on the Deployment
Gates Evaluations page in Datadog - so you can validate the rule behaves as expected
before it can actually block a rollout.
