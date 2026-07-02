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
ENV FAULT_LATENCY_MS=600
ENV FAULT_ERROR_RATE=0.25
