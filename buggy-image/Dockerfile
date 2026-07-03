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
# Escalated live during gate-FAIL debugging: 600ms/25% wasn't enough to trip
# Faulty Deployment Detection even with a 900s window and dedicated sustained
# load (see rollouts/deployment-gates-guide.md) - discounts already has several
# seconds of baseline latency and low natural throughput, which buried a
# moderate regression in noise. Escalated to a near-total outage so it's
# unambiguous regardless of sample size.
ENV FAULT_LATENCY_MS=5000
ENV FAULT_ERROR_RATE=0.9
