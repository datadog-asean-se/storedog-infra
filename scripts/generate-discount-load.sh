#!/usr/bin/env bash
# Generate a steady stream of requests directly against the `discounts` Service
# so Watchdog APM Faulty Deployment Detection has enough sample volume to reach
# a confident verdict during the Deployment Gate's analysis window.
#
# Found live: the optional k8s-manifests/fake-traffic/puppeteer.yaml generator
# simulates realistic (slow) browsing sessions - roughly one discounts request
# every ~10s. That's nowhere near enough volume for Watchdog to distinguish a
# real regression from noise within any reasonably-sized analysis window.
#
# IMPORTANT - sequential, not concurrent, and no artificial rate limit needed:
# also found live (twice - once with a hand-rolled concurrent loop, once with
# k6's constant-arrival-rate executor) - the `discounts` Flask app runs on
# Werkzeug's single-threaded development server ("This is a development
# server..."), AND its discount-listing endpoint appears to do an O(n)
# relationship lookup per row (classic N+1 query pattern) against a table that
# only grows over repeated demo runs. Independently of any injected fault, a
# single healthy request routinely took 2.5-8+ seconds end to end (confirmed by
# gaps between the app's own log lines within a single trace, not just
# client-side/network latency). Firing several requests per second - even
# through a properly rate-limited tool - queues them up behind that single
# worker and produces request timeouts on the HEALTHY pods too, polluting the
# baseline Watchdog compares against and defeating the whole point of the test.
#
# The fix here is to NOT fight the app's real capacity: issue one request,
# wait for it to fully complete (however long that takes), then immediately
# issue the next - no concurrency, no artificial per-request delay beyond what
# the app itself needs. This is the fastest sustainable rate a single caller
# can push without inducing queueing artifacts, and is why this script's
# default duration is long enough to line up with the 900s gate window (see
# rollouts/deployment-gate-cluster-analysis-template.yaml) rather than trying
# to cram more throughput into a short one.
#
# Usage:
#   ./scripts/generate-discount-load.sh [duration_seconds]
set -euo pipefail

NS="${NS:-storedog}"
DURATION="${1:-1020}"  # default covers the 60s pause + 900s analysis + buffer
POD_NAME="discount-load-gen-$(date +%s)"

echo ">> generating back-to-back sequential requests (no concurrency, no artificial delay) against discounts.${NS}.svc.cluster.local:2814/discount for ${DURATION}s"
kubectl -n "$NS" run "$POD_NAME" --rm -i --restart=Never --image=busybox:1.37.0 --command -- \
  sh -c "
    end=\$(( \$(date +%s) + ${DURATION} ))
    count=0
    while [ \$(date +%s) -lt \$end ]; do
      wget -q -O /dev/null --timeout=15 'http://discounts.${NS}.svc.cluster.local:2814/discount'
      count=\$((count + 1))
    done
    echo \"load generation complete: \${count} sequential requests\"
  "
