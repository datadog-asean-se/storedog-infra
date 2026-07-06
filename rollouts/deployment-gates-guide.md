# Setting up the Deployment Gate policy

This document walks through the Datadog **Deployment Gate** used by
`rollouts/discounts-rollout.yaml`, why it's implemented the way it is, and how to
adapt it for your own service.

> ## ✅ Resolved: gate FAIL→rollback confirmed live (via a second `monitor` rule)
>
> **Both directions of the gate are now proven live** against this demo's Datadog
> org, with hard evidence for each:
>
> - **FAIL -> automatic rollback**: triggered the buggy canary
>   (`version:bad-20260706170126`) at 50% canary weight. The gate's Job logged
>   `❌ Gate evaluation failed`, evaluation ID `24209bf8-48c7-4c38-99f0-5547b1352b97`,
>   with the `store-discounts error rate monitor` rule reporting
>   `Status: FAIL`, `Reason: One or more monitors in ALERT state:
>   https://.../monitors/302826417`. Confirmed independently via a direct
>   `GET /api/v2/deployments/gates/evaluation/24209bf8-48c7-4c38-99f0-5547b1352b97`
>   call (`"gate_status":"fail"`), not just the `datadog-ci` CLI's own report.
>   **Argo Rollouts itself then genuinely aborted and rolled back**: `kubectl argo
>   rollouts get rollout discounts` showed `Status: ✖ Degraded`,
>   `Message: RolloutAborted: ... Metric "datadog-deployment-gate" assessed
>   Failed`, `SetWeight: 0`, the canary ReplicaSet `ScaledDown`, and the stable
>   ReplicaSet scaled back to its full desired replica count on the healthy
>   `:good` image - not just an isolated CLI exit code, an actual live rollback.
> - **PASS -> promote**: after resetting to the healthy `:good` image and letting
>   the monitor's trailing 5-minute window clear (see the operational note
>   below), a follow-up attempt's `AnalysisRun` reported `✔ Successful` and the
>   `Rollout` reached `Status: ✔ Healthy`, `SetWeight: 100` on the `:good` image.
>
> This was **not** achieved by relying on `faulty_deployment_detection` /
> Watchdog alone - that rule was still `IN_PROGRESS` when both gate evaluations
> above resolved (the gate fails as soon as any required rule definitively
> fails, per "all rules must pass"; it doesn't wait for every rule to finish).
> The `monitor` rule (added specifically because Watchdog wasn't reliably
> flagging real regressions - see the retained history below) is what actually
> produced the FAIL. **Whether `faulty_deployment_detection` alone would ever
> have failed on this same regression remains unconfirmed** - the monitor rule
> resolved the gate before it finished evaluating in every attempt.
>
> **A real dilution/weighting bug had to be fixed first** - see the "Gotcha"
> note under "How the `monitor` rule works" below for the full arithmetic. In
> short: the monitor's query aggregates errors/hits across both canary and
> stable pods (scoped by `service`, not `version`), so at the original 25%
> canary weight and 45% fault rate, the aggregate error rate the monitor could
> ever see was capped at `0.25 x 0.45 = 11.25%` - permanently below the original
> 15% critical threshold no matter how much traffic was generated. Fixed with
> two levers together: canary `setWeight` raised 25% -> 50%
> (`rollouts/discounts-rollout.yaml`) and the monitor's thresholds lowered
> 15%/8% -> 8%/4% critical/warning (`terraform/monitor.tf`), giving a confirmed
> live aggregate of well over 40% against an 8% threshold - ample margin.
>
> **Operational note found live**: after a FAIL/rollback, the monitor stays in
> `Alert` state for its trailing 5-minute window even once traffic is clean
> again. A `good`-image verification run immediately after a `FAIL` attempt
> failed for the same monitor-in-Alert reason, purely because the window hadn't
> cleared yet - not a new bug, just residual state. Wait for the monitor to show
> `OK` (`GET /api/v1/monitor/<id>`) before re-running a verification, or budget
> for one retry.
>
> <details>
> <summary>Retained history: what led to adding the <code>monitor</code> rule</summary>
>
> The PASS→promote path was fully proven live first (real evaluation IDs, real
> API confirmation, real promotion to `setWeight: 100`). The FAIL→rollback path
> was not: across 8 live attempts relying on `faulty_deployment_detection`
> alone, the gate **passed every time**, including an attempt with airtight
> evidence of a real, fully-instrumented regression. That was root-caused to two
> issues, both fixed along the way:
>
> - **The actual root cause of early attempts' near-zero error-span counts**:
>   `buggy-image/sitecustomize.py` used to inject the fault by monkeypatching
>   `Flask.wsgi_app` directly and calling `start_response()` itself - bypassing
>   Flask's (and therefore ddtrace's Flask integration's) normal request/exception
>   dispatch entirely for the faulty code path. Those 500s were real HTTP
>   responses but were never recorded as APM errors at all. Fixed by rewriting
>   the fault injection as a Flask `before_request` hook + `flask.abort(500)`,
>   which flows through Flask's normal exception handling and is fully visible
>   to ddtrace.
> - After that fix, error spans showed up correctly (228 errors / 328 requests,
>   ~70% error rate, vs. a 0-error/318-request healthy baseline, both confirmed
>   via the Spans Analytics API) over Datadog's own recommended 900s window -
>   and `faulty_deployment_detection` **still returned `pass`** (evaluation ID
>   `bc3c355d-f4b6-47c6-b9ae-5728d766584c`, confirmed via a direct
>   `GET /api/v2/deployments/gates/evaluation/<id>` call). Org-level retention
>   filters and client-side trace sampling (`DD_TRACE_SAMPLE_RATE=1.0`, still set
>   in `rollouts/discounts-rollout.yaml`) were both checked and ruled out as
>   explanations.
>
> **This remains an open, unexplained question about `faulty_deployment_detection`
> / Watchdog specifically** - not resolved, just no longer blocking the demo,
> since the `monitor` rule now reliably catches the same class of regression.
> If you rely on `faulty_deployment_detection` alone (no `monitor` rule) for
> your own service, budget time to validate it the same way this session did,
> and consider asking Datadog support if you hit the same non-detection,
> referencing evaluation ID `bc3c355d-f4b6-47c6-b9ae-5728d766584c` above.
>
> </details>

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

## How the `monitor` rule works (the second gate rule)

Added after the "Known gap" investigation below: a second rule, of type `monitor`,
checks a real, deterministic Datadog Monitor's state instead of relying on
Watchdog's ML-based confidence scoring. **Both rules must pass for the gate to
pass** - the JIT docs are explicit: "All rules must pass for the gate to pass."
There's no ANY/OR semantic across rules in a single gate.

Per the [JIT rule-types docs](https://docs.datadoghq.com/deployment_gates/setup/jit/)
("Monitor" tab, fetched 2026-07-06), this rule type is fundamentally different from
`faulty_deployment_detection`:

- **It requires a pre-existing Datadog Monitor object.** Unlike
  `faulty_deployment_detection` (fully self-contained/inline, no Datadog-side setup),
  the `monitor` rule evaluates the state of **existing** monitors - there's nothing to
  create inline. This repo provisions that monitor as real Terraform IaC:
  [`terraform/monitor.tf`](../terraform/monitor.tf) -> `datadog_monitor.discounts_error_rate`.
- **The rule's `options.query` is a Monitor Search query, not a monitor ID.** There is
  no `monitor_id` field for this rule type (verify this yourself before assuming
  otherwise - it's an easy wrong guess). The docs' own schema:

  ```json
  {
    "type": "monitor",
    "name": "Service monitors",
    "options": {
      "query": "service:transaction-backend env:production",
      "duration": 300
    }
  }
  ```

  `query` uses [Monitor Search](https://docs.datadoghq.com/monitors/manage/search/)
  syntax and can filter on: a monitor's static tags (`service:transaction-backend`),
  tags inside the monitor's own query (`scope:"service:transaction-backend"`), or
  tags within a monitor grouping (`group:"service:transaction-backend"`).
- **Fail conditions** (evaluated continuously for `options.duration` seconds,
  default 0 = instant, max 7200): the gate rule fails if, at any point in that
  window: no monitors match the query, more than 50 monitors match, or **any**
  matching monitor is in `ALERT` or **`NO_DATA`** state. Muted monitors are excluded
  automatically (the query always implicitly includes `muted:false`).

### The monitor this repo creates

[`terraform/monitor.tf`](../terraform/monitor.tf) creates a single `metric alert`
monitor tagged `gate:discounts-error-rate` (a dedicated tag, not just
`service:store-discounts`, so the gate's search query stays unambiguous even if more
monitors get added for this service later):

```hcl
query = "sum(last_5m):( sum:trace.flask.request.errors{service:store-discounts}.as_count() / sum:trace.flask.request.hits{service:store-discounts}.as_count() ) * 100 > 15"

monitor_thresholds {
  critical = "15"
  warning  = "8"
}
```

- **Metric names verified live**, not guessed: `GET /api/v1/search?q=metrics:flask`
  against this org returned `trace.flask.request.hits` and `trace.flask.request.errors`
  - the standard ddtrace-generated APM count metrics for a Flask service's default
  `flask.request` span. Confirmed both carry real data tagged `service:store-discounts`
  via direct `GET /api/v1/query` timeseries calls before wiring them into the monitor.
- **Threshold rationale**, from this session's own live measurements (see the "Known
  gap" section below): a healthy baseline measured **0% errors over 318 requests**,
  while the buggy canary measured **~70% errors over 328 requests**. 15%
  critical / 8% warning sits comfortably above normal noise and well below what this
  demo's `:buggy` image reliably reproduces.
- **Gotcha: this monitor is scoped by `service`, not `version` - dilution math
  matters.** The query aggregates errors/hits across **both** the healthy stable
  pods and the buggy canary pod, since they share `service:store-discounts` and
  differ only by the `version` tag (which the query doesn't filter on). During the
  canary step (`setWeight: 25`), only 25% of Service traffic reaches the buggy pod;
  the other 75% hits the stable pods at ~0% errors. The resulting **aggregate**
  error rate the monitor actually sees is a weighted average -
  `canary_weight x FAULT_ERROR_RATE` - not the raw fault rate itself. Found live:
  at `FAULT_ERROR_RATE=0.45` and 25% canary weight, the ceiling is
  `0.25 x 0.45 = 11.25%`, permanently below the 15% critical threshold **no matter
  how much traffic you generate** - more volume just converges the measurement on
  11.25%, it never crosses 15%. This is a dilution/weighting problem, not a
  sample-size problem, and is easy to miss if you only think about "is the fault
  severe enough" without accounting for canary weight. See `buggy-image/Dockerfile`
  for the corrected math (`FAULT_ERROR_RATE=0.90` -> `0.25 x 0.90 = 22.5%`, clear of
  threshold with margin). If you build a similar service-level (not version-scoped)
  monitor for your own canary gate, either scope the monitor's query by `version`
  too (if your rollout tool propagates a `version` tag Datadog can filter on), or
  do this same weighted-average math against your actual canary `setWeight` before
  picking a threshold and fault severity.
- The gate's rule references it via
  `"query": "tag:\"gate:discounts-error-rate\""` - verified live to match exactly
  this one monitor via `GET /api/v1/monitor/search?query=tag:"gate:discounts-error-rate"`.
- **Operational caveat**: since the `monitor` rule also fails on `NO_DATA`, this
  monitor needs *some* traffic flowing to `store-discounts` during the gate's
  evaluation window (guaranteed in this repo by `fake-traffic/puppeteer.yaml` and/or
  `scripts/generate-discount-load.sh`) - `notify_no_data = false` and
  `require_full_window = false` are set on the monitor to avoid spurious notifications
  and premature failures in the first few minutes after a fresh deploy, but a
  genuinely traffic-less service would still eventually show `NO_DATA` and fail this
  rule. Get the monitor via
  `terraform output discounts_error_rate_monitor_id` /
  `terraform output discounts_error_rate_monitor_url`, or directly:
  `dotenvx run -- terraform apply -target=datadog_monitor.discounts_error_rate` (no
  dependency on the GKE cluster resources - safe to create/update without touching
  the ephemeral cluster).
- **Not yet validated live end-to-end**: this rule was added and the monitor
  independently confirmed live (via the Datadog API) in a session where the demo
  cluster was intentionally *not* running, per a request to add this IaC without
  incurring cluster cost. It has not yet been exercised through an actual canary +
  gate run. Given it's a plain deterministic threshold (not an ML confidence score),
  it's expected to be a more reliable FAIL trigger than `faulty_deployment_detection`
  alone given the Watchdog sensitivity gap documented below - but that is a
  prediction, not a confirmed result, until someone runs the live demo again.
- **No shared Terraform state**: this repo has no configured remote backend (see the
  commented-out `backend "gcs"` block in `terraform/versions.tf`) - state is local to
  whoever last ran `terraform apply`. The monitor is a persistent, reusable object
  (unlike the ephemeral GKE cluster), so before running `terraform apply` fresh,
  check whether it already exists (search for the `gate:discounts-error-rate` tag in
  the Datadog UI or via `GET /api/v1/monitor/search`) and `terraform import` it
  instead of creating a duplicate - see the comment at the top of `terraform/monitor.tf`.

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
