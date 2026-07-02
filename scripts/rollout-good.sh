#!/usr/bin/env bash
# DEMO RESET: roll out the HEALTHY discounts image via GitOps.
# The Deployment Gate passes and the canary promotes to 100%.
set -euo pipefail
source "$(dirname "$0")/_rollout-common.sh"

GOOD_TAG="${GOOD_TAG:-good}"
VERSION="${VERSION:-good-$(date +%Y%m%d%H%M%S)}"

apply_change "$GOOD_TAG" "$VERSION" \
  "demo: roll back to healthy discounts (${VERSION}) - Deployment Gate should pass"
