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
# This script exists to make the Deployment Gate demo reliable: run it
# concurrently with scripts/rollout-bad.sh / rollout-good.sh so there's real
# statistical signal for Faulty Deployment Detection to evaluate.
#
# Usage:
#   ./scripts/generate-discount-load.sh [duration_seconds] [requests_per_second]
set -euo pipefail

NS="${NS:-storedog}"
DURATION="${1:-360}"
RPS="${2:-5}"
POD_NAME="discount-load-gen-$(date +%s)"

echo ">> generating ~${RPS} req/s against discounts.${NS}.svc.cluster.local:2814/discount for ${DURATION}s"
kubectl -n "$NS" run "$POD_NAME" --rm -i --restart=Never --image=busybox:1.37.0 --command -- \
  sh -c "
    end=\$(( \$(date +%s) + ${DURATION} ))
    while [ \$(date +%s) -lt \$end ]; do
      for i in \$(seq 1 ${RPS}); do
        wget -q -O /dev/null --timeout=2 'http://discounts.${NS}.svc.cluster.local:2814/discount' &
      done
      wait
      sleep 1
    done
    echo 'load generation complete'
  "
