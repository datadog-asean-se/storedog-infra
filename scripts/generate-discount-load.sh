#!/usr/bin/env bash
# Generate a tight loop of requests directly against the `discounts` Service so
# Watchdog APM Faulty Deployment Detection has enough sample volume to reach a
# confident verdict during the Deployment Gate's analysis window.
#
# Found live: the optional k8s-manifests/fake-traffic/puppeteer.yaml generator
# simulates realistic (slow) browsing sessions - roughly one discounts request
# every ~10s. Over a 300s gate analysis window at 25% canary weight, that's only
# ~2-3 actual HTTP requests reaching the canary pod - nowhere near enough volume
# for Watchdog to distinguish a real regression from noise, regardless of how
# severe the injected fault is or how the request cadence maps to error rate.
#
# IMPORTANT - sequential, not concurrent: also found live - the `discounts`
# Flask app runs on Werkzeug's single-threaded development server ("This is a
# development server..."), not a production WSGI server. An earlier version of
# this script fired several concurrent requests per second, which overwhelmed
# the dev server enough to produce real request failures/timeouts on the
# HEALTHY ("good") pods too - polluting the baseline Watchdog compares against
# and defeating the whole point of the test. Requests here are issued strictly
# one-at-a-time (each request completes, including the buggy image's injected
# +600ms latency, before the next fires) so only the buggy image's genuinely
# injected faults show up as errors, not client-side overload artifacts.
#
# Usage:
#   ./scripts/generate-discount-load.sh [duration_seconds] [interval_seconds]
set -euo pipefail

NS="${NS:-storedog}"
DURATION="${1:-360}"
INTERVAL="${2:-1}"
POD_NAME="discount-load-gen-$(date +%s)"

echo ">> generating 1 sequential request every ${INTERVAL}s against discounts.${NS}.svc.cluster.local:2814/discount for ${DURATION}s"
kubectl -n "$NS" run "$POD_NAME" --rm -i --restart=Never --image=busybox:1.37.0 --command -- \
  sh -c "
    end=\$(( \$(date +%s) + ${DURATION} ))
    count=0
    while [ \$(date +%s) -lt \$end ]; do
      wget -q -O /dev/null --timeout=5 'http://discounts.${NS}.svc.cluster.local:2814/discount'
      count=\$((count + 1))
      sleep ${INTERVAL}
    done
    echo \"load generation complete: \${count} sequential requests\"
  "
