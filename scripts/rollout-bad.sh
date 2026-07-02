#!/usr/bin/env bash
# DEMO: roll out the BUGGY discounts image via GitOps.
# ArgoCD syncs -> Argo Rollouts canary -> Deployment Gate (faulty_deployment_detection)
# detects the regression -> gate FAILS -> rollout auto-aborts and rolls back.
set -euo pipefail
source "$(dirname "$0")/_rollout-common.sh"

BUGGY_TAG="${BUGGY_TAG:-buggy}"
# Monotonic, unique version so Faulty Deployment Detection treats it as a new release.
VERSION="${VERSION:-bad-$(date +%Y%m%d%H%M%S)}"

apply_change "$BUGGY_TAG" "$VERSION" \
  "demo: roll out buggy discounts (${VERSION}) - should trip the Deployment Gate"
