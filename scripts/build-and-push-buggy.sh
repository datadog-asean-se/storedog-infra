#!/usr/bin/env bash
# Build the buggy discounts image (and a clean "good" tag) and push to a registry.
set -euo pipefail

# e.g. REGISTRY=asia-southeast1-docker.pkg.dev/datadog-ese-sandbox/storedog
REGISTRY="${REGISTRY:?set REGISTRY, e.g. asia-southeast1-docker.pkg.dev/<project>/storedog}"
BASE_IMAGE="${BASE_IMAGE:-ghcr.io/datadog/storedog/discounts:latest}"
BUGGY_TAG="${BUGGY_TAG:-buggy}"
GOOD_TAG="${GOOD_TAG:-good}"

HERE="$(cd "$(dirname "$0")/../buggy-image" && pwd)"

echo ">> building buggy image ${REGISTRY}/discounts:${BUGGY_TAG}"
docker build --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  -t "${REGISTRY}/discounts:${BUGGY_TAG}" "${HERE}"
docker push "${REGISTRY}/discounts:${BUGGY_TAG}"

echo ">> tagging clean base as ${REGISTRY}/discounts:${GOOD_TAG}"
docker pull "${BASE_IMAGE}"
docker tag "${BASE_IMAGE}" "${REGISTRY}/discounts:${GOOD_TAG}"
docker push "${REGISTRY}/discounts:${GOOD_TAG}"

echo ">> done. Use these tags in scripts/rollout-bad.sh (buggy) and rollout-good.sh (good)."
