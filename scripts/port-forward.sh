#!/usr/bin/env bash
# Reach the storedog storefront WITHOUT a public LoadBalancer/Ingress
# (org policy forbids 0.0.0.0/0 firewall rules). Uses kubectl port-forward.
set -euo pipefail

NS="${NS:-storedog}"
SVC="${SVC:-service-proxy}"     # storedog nginx service
LOCAL_PORT="${LOCAL_PORT:-8088}"
REMOTE_PORT="${REMOTE_PORT:-80}"

echo "Forwarding http://localhost:${LOCAL_PORT} -> svc/${SVC}:${REMOTE_PORT} (ns=${NS})"
echo "Open http://localhost:${LOCAL_PORT} in your browser. Ctrl-C to stop."
exec kubectl -n "${NS}" port-forward "svc/${SVC}" "${LOCAL_PORT}:${REMOTE_PORT}"
