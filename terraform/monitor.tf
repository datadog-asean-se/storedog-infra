# Datadog Monitor backing the second Deployment Gates JIT rule (type: "monitor"),
# alongside the existing `faulty_deployment_detection` rule - see
# rollouts/deployment-gate-cluster-analysis-template.yaml and
# rollouts/deployment-gates-guide.md for the full writeup.
#
# Why this exists: a live end-to-end test this session found that Watchdog APM
# Faulty Deployment Detection did not flag a real, fully-instrumented ~70% error
# rate regression on `store-discounts` (see the "Known gap" section of
# rollouts/deployment-gates-guide.md). A `monitor` rule with a deterministic
# metric threshold does not depend on Watchdog's ML-based confidence scoring at
# all, so it's expected to be a more reliable trigger for the gate FAIL demo path.
#
# Metric names verified live against this Datadog org via the API (not guessed):
#   GET https://api.datadoghq.com/api/v1/search?q=metrics:flask
# returned (among others) `trace.flask.request.hits` and `trace.flask.request.errors`
# - the standard ddtrace-generated APM count metrics for a Flask service's default
# `flask.request` span, confirmed to carry real, non-empty data tagged
# `service:store-discounts` via a direct
# GET https://api.datadoghq.com/api/v1/query timeseries query.
#
# IMPORTANT - this repo has no shared Terraform state (see the commented-out `backend
# "gcs"` block in versions.tf): state is local to whoever last ran `terraform apply`.
# The monitor is a PERSISTENT, reusable Datadog object (unlike the ephemeral GKE
# cluster), so if you don't already have this in your local state, check first
# whether it already exists before creating a duplicate:
#   dotenvx run -- bash -c 'curl -s -G "https://api.datadoghq.com/api/v1/monitor/search" \
#     --data-urlencode "query=tag:\"gate:discounts-error-rate\"" \
#     -H "DD-API-KEY: $DD_API_KEY" -H "DD-APPLICATION-KEY: $DD_APP_KEY"'
# If it exists, import it instead of applying fresh:
#   dotenvx run -- terraform import datadog_monitor.discounts_error_rate <existing-id>
#
# Threshold rationale (from this session's own live measurements):
#   - Healthy baseline (`discounts:good`, `version:1.0.0`): 318 requests, 0 errors
#     over the session -> ~0% error rate.
#   - Buggy canary (`discounts:buggy`, 45% injected fault rate): 328 requests,
#     228 errors -> ~70% error rate.
#
# IMPORTANT - dilution math (found live wiring this rule into the canary Rollout,
# see rollouts/deployment-gates-guide.md's "Gotcha" note and
# buggy-image/Dockerfile): this query is scoped by `service`, not `version`, so
# it aggregates errors/hits across BOTH the healthy stable pods and the buggy
# canary pod. At `canary_weight` traffic share, the monitor only ever sees
# `canary_weight x FAULT_ERROR_RATE`, never the raw configured fault rate. At the
# original 25% canary weight and 45% fault rate, the ceiling was
# 0.25 x 0.45 = 11.25% - permanently below a 15% critical threshold no matter how
# much traffic was generated. Fixed with TWO levers together (not just a higher
# fault rate): the canary's `setWeight` was raised to 50%
# (rollouts/discounts-rollout.yaml) AND the thresholds below were lowered to
# 8% critical / 4% warning. At 50% canary weight and the current
# FAULT_ERROR_RATE=0.90 (buggy-image/Dockerfile), the expected aggregate is
# 0.50 x 0.90 = 45% - clears the 8% critical threshold with very large margin
# (>5x), comfortably above normal noise (0%) on the healthy baseline.
resource "datadog_monitor" "discounts_error_rate" {
  name    = "[storedog-adlc-demo] store-discounts error rate"
  type    = "metric alert"
  message = <<-EOT
    {{#is_alert}}
    `store-discounts` error rate is above 8% over the last 5 minutes - likely the
    injected fault in the storedog-infra Deployment Gate demo's `:buggy` discounts
    image (see buggy-image/ in datadog-asean-se/storedog-infra), or a real
    regression if you're not running that demo.
    {{/is_alert}}
    {{#is_recovery}}
    `store-discounts` error rate is back under 4%.
    {{/is_recovery}}
  EOT

  # Ratio of error count to total request count over a trailing 5-minute window,
  # as a percentage. `.as_count()` is required on these APM hit/error metrics
  # (rate-type metrics) before they can be used in an arithmetic formula.
  query = "sum(last_5m):( sum:trace.flask.request.errors{service:store-discounts}.as_count() / sum:trace.flask.request.hits{service:store-discounts}.as_count() ) * 100 > 8"

  monitor_thresholds {
    critical = "8"
    warning  = "4"
  }

  # This demo's traffic (fake-traffic/puppeteer.yaml + scripts/generate-discount-load.sh)
  # is intermittent by design between demo runs. Deployment Gates' `monitor` rule
  # type fails the gate if a matching monitor is in ALERT *or* NO_DATA state (per
  # https://docs.datadoghq.com/deployment_gates/setup/jit/), so avoid spurious
  # NO_DATA-driven gate failures between runs: don't notify on missing data, and
  # don't evaluate the full window strictly (so the first few minutes after a
  # fresh deploy - before 5 minutes of data has accumulated - don't count as a
  # failure on their own).
  notify_no_data      = false
  no_data_timeframe   = 20
  require_full_window = false
  renotify_interval   = 0
  include_tags        = true

  # Static tags on the monitor object - the Deployment Gates `monitor` rule type's
  # `query` (Monitor Search syntax) matches against these directly. Using a
  # dedicated `gate:` tag (rather than just `service:store-discounts`) keeps the
  # gate's rule query unambiguous even if more monitors get added for this
  # service later.
  tags = [
    "service:store-discounts",
    "team:discounts",
    "env:demo",
    "gate:discounts-error-rate",
    "purpose:adlc-datadog-demo",
  ]
}

output "discounts_error_rate_monitor_id" {
  description = "Real Datadog Monitor ID backing the gate's `monitor` rule - reference this (or the gate: tag) from rollouts/deployment-gate-cluster-analysis-template.yaml's ConfigMap."
  value       = datadog_monitor.discounts_error_rate.id
}

output "discounts_error_rate_monitor_url" {
  value = "https://app.datadoghq.com/monitors/${datadog_monitor.discounts_error_rate.id}"
}
