# Pre-built "buggy" discounts image for the Deployment Gate demo.
#
# Extends the stock storedog discounts image and layers in fault injection so this
# specific tag reliably trips Watchdog APM Faulty Deployment Detection:
#   - +latency on every request (sitecustomize.py)
#   - a burst of 5xx errors (sitecustomize.py + the app's built-in BROKEN_DISCOUNTS)
#
# Build + push:  ../scripts/build-and-push-buggy.sh
ARG BASE_IMAGE=ghcr.io/datadog/storedog/discounts:latest
FROM ${BASE_IMAGE}

# Drop the fault shim onto PYTHONPATH so Python auto-imports it at startup.
COPY sitecustomize.py /faults/sitecustomize.py
ENV PYTHONPATH=/faults

# Turn on the app's built-in random-error path too (see discounts.py).
ENV BROKEN_DISCOUNTS=ENABLED
# Dialed back to a more demo-realistic "clearly broken, not a total outage"
# severity after finding and fixing the actual root cause of prior gate-FAIL
# attempts never triggering: sitecustomize.py used to inject the fault by
# monkeypatching Flask.wsgi_app directly, which bypassed ddtrace's Flask
# instrumentation entirely for the faulty code path, so those 500s were never
# recorded as APM errors at all (near-zero error spans regardless of fault
# severity or gate window - see rollouts/deployment-gates-guide.md). Now that
# the fault is injected via a proper before_request/abort(500) hook (traced
# correctly), a moderate regression should be plenty.
ENV FAULT_LATENCY_MS=1500
#
# FAULT_ERROR_RATE math (found live while wiring up the `monitor` gate rule -
# see terraform/monitor.tf and rollouts/deployment-gates-guide.md): the
# monitor's query (`sum:trace.flask.request.errors{service:store-discounts} /
# sum:trace.flask.request.hits{service:store-discounts}`) is scoped by
# `service`, not `version` - it aggregates BOTH the healthy stable pods and the
# buggy canary pod together, since they share the same `service:store-discounts`
# tag. During the canary step (`setWeight: 25` in discounts-rollout.yaml), only
# 25% of Service traffic reaches the buggy pod; the other 75% hits the healthy
# stable pods at ~0% errors. The resulting AGGREGATE error rate is a weighted
# average: 0.25 x FAULT_ERROR_RATE - NOT the raw FAULT_ERROR_RATE itself. At the
# previous 0.45 setting, that's only 0.25 x 0.45 = 11.25%, permanently below the
# monitor's 15% critical threshold no matter how much traffic is generated (more
# volume converges the measurement on 11.25%, it never crosses 15% - this is a
# dilution/weighting problem, not a sample-size problem). Set high enough that
# 0.25 x FAULT_ERROR_RATE clears 15% with real margin:
#   0.25 x 0.70 = 17.5%  (only ~2.5pp margin - too tight given real-world noise)
#   0.25 x 0.90 = 22.5%  (comfortable margin - used here)
ENV FAULT_ERROR_RATE=0.90
