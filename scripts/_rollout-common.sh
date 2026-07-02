#!/usr/bin/env bash
# Shared helper for the GitOps rollout demo scripts.
#
# apply_change <image-tag> <version> <commit-message>
#   Edits the discounts Rollout manifest in a GitOps checkout to point at a new
#   image tag + version, then commits and pushes so ArgoCD syncs and Argo Rollouts
#   performs a canary + Deployment Gate analysis.
#
# Required env:
#   GITOPS_DIR   path to the GitOps repo checkout (holds the rendered manifests)
#   REGISTRY     registry base, e.g. asia-southeast1-docker.pkg.dev/<project>/storedog
# Optional env:
#   ROLLOUT_FILE relative path to the discounts rollout manifest
#                (default: rollouts/discounts-rollout.yaml)
#   GIT_REMOTE   default: origin
#   GIT_BRANCH   default: main
set -euo pipefail

: "${GITOPS_DIR:?set GITOPS_DIR to your GitOps repo checkout}"
: "${REGISTRY:?set REGISTRY, e.g. asia-southeast1-docker.pkg.dev/<project>/storedog}"
ROLLOUT_FILE="${ROLLOUT_FILE:-rollouts/discounts-rollout.yaml}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
GIT_BRANCH="${GIT_BRANCH:-main}"

apply_change() {
  local tag="$1" version="$2" message="$3"
  local file="${GITOPS_DIR}/${ROLLOUT_FILE}"
  [ -f "$file" ] || { echo "manifest not found: $file" >&2; exit 1; }

  local image="${REGISTRY}/discounts:${tag}"
  echo ">> setting image=${image}  version=${version}"

  # 1) container image
  sed -i.bak -E "s#image: .*discounts:[A-Za-z0-9._-]+#image: ${image}#g" "$file"

  # 2) tags.datadoghq.com/version label (Rollout metadata + pod template)
  sed -i.bak -E "s#(tags\.datadoghq\.com/version: ).*#\1\"${version}\"#g" "$file"

  # 3) DD_VERSION env value (the line immediately after `name: DD_VERSION`)
  awk -v v="$version" '
    prev ~ /name: DD_VERSION/ && $0 ~ /value:/ { sub(/value:.*/, "value: \"" v "\"") }
    { print; prev=$0 }
  ' "$file" > "${file}.awk" && mv "${file}.awk" "$file"

  rm -f "${file}.bak"

  ( cd "$GITOPS_DIR" \
    && git add "$ROLLOUT_FILE" \
    && git commit -m "$message" \
    && git push "$GIT_REMOTE" "$GIT_BRANCH" )

  echo ">> pushed. ArgoCD will sync; watch with:"
  echo "   kubectl argo rollouts get rollout discounts -n storedog --watch"
}
