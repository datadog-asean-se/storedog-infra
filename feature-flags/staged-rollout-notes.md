# Feature Flags staged rollout with metric-based auto-pause (B6)

The third Deploy-phase control (after Synthetics CI gate and Deployment Gates). This
reuses storedog's existing Feature Flags workshop and frames it as a **staged rollout
that pauses/aborts itself when a monitored metric degrades**.

## What storedog already gives us

Storedog ships fault-injection feature flags in
`services/frontend/site/featureFlags.config.json`:

| Flag | Effect | Good "degradation" signal to guard on |
|---|---|---|
| `error-tracking` | 500s from the Ads service | APM error rate on `store-ads` / `store-frontend` |
| `api-errors` | random 400/500 on frontend `/api/*` | RUM error rate / APM `store-frontend-api` errors |
| `product-card-frustration` | broken product thumbnails | RUM Frustration Signals (rage/dead clicks) |
| `dbm` | long-running query ticker | DBM / Postgres query latency |

## Demo shape (staged rollout with wait schedule + auto-pause)

1. Start the feature at a small exposure (e.g. 10%) with a **wait schedule**
   (10% -> wait -> 50% -> wait -> 100%).
2. Attach a **monitored metric / monitor** as the guardrail (e.g. RUM error rate for the
   frontend, or APM error rate for `store-ads`).
3. Flip the fault-injection flag (`error-tracking` or `api-errors`) so the guarded
   metric degrades.
4. Show the staged rollout **auto-pause / abort** when the metric crosses threshold -
   the post-deploy kill-switch.

## Two ways to drive it

- **Datadog Feature Flags** (OpenFeature) with a metric-based guardrail on the rollout
  step - the platform pauses the ramp automatically on degradation. (Mirrors the pattern
  used in the `dd-se-sales-assistant` app's Datadog Feature Flags setup.)
- **storedog's built-in flag file** for a purely local demo: edit
  `featureFlags.config.json` (mounted into the frontend) to flip a fault flag, and pair
  with a Datadog **monitor** that you show pausing the rollout narrative.

## Talk track

"Synthetics catches it before prod. Deployment Gates catch it in the canary. Feature
Flags give you a metric-guarded kill-switch *after* deploy. Defense in depth so you can
ship at AI speed without shipping incidents."
