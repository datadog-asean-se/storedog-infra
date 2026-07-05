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
ENV FAULT_ERROR_RATE=0.45
