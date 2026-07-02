# k8s-manifests — storedog on GKE

Kubernetes manifests for the storedog app, adapted from
[`datadog-asean-se/storedog`](https://github.com/datadog-asean-se/storedog)'s
`docker-compose.yml` for a GKE + ArgoCD GitOps deployment.

## docker-compose -> Kubernetes mapping

| docker-compose service | Manifest here | Datadog service tag |
|---|---|---|
| `frontend` (Next.js) | `deployments/frontend.yaml` | `store-frontend-api` (+ RUM `store-frontend`) |
| `backend` (Rails/Spree) | `deployments/backend.yaml` | `store-backend` |
| `worker` (Sidekiq) | `deployments/worker.yaml` | `store-worker` |
| `discounts` (Flask) | **`../rollouts/discounts-rollout.yaml`** (Argo Rollout, not here) | `store-discounts` |
| `ads` (Java) | `deployments/ads.yaml` | `store-ads` |
| `service-proxy` (nginx) | `deployments/nginx.yaml` | `service-proxy` |
| `postgres` | `statefulsets/postgres.yaml` | `store-db` |
| `redis` | `statefulsets/redis.yaml` | `redis` |
| `dd-agent` | `datadog/datadog-agent.yaml` (Datadog Operator CR) | — |
| `puppeteer` | `fake-traffic/puppeteer.yaml` (optional) | RUM traffic gen |

`discounts` is deliberately **not** a plain Deployment here — it's an Argo `Rollout`
in `../rollouts/` so it can canary and be gated by the Datadog Deployment Gate.

## GKE-specific adaptations vs upstream

1. **No shell templating.** Upstream uses `envsubst` with `${REGISTRY_URL}`,
   `${SD_TAG}`, `${DD_VERSION_*}` placeholders for lab environments. ArgoCD applies
   raw manifests with no substitution step, so every value here is **pinned** to a
   concrete default (`ghcr.io/datadog/storedog/*:latest`, `DD_VERSION=1.0.0`, etc.).
   To bump a version: edit the manifest, commit, push - ArgoCD syncs it. That commit
   *is* the GitOps release.
2. **Storage.** Skips upstream's `cluster-setup/` (Rancher local-path provisioner).
   GKE's default `standard-rwo` StorageClass satisfies the Postgres/Redis PVCs.
3. **No public exposure.** `service-proxy`'s Service stays `ClusterIP`. Reach the
   storefront with `../scripts/port-forward.sh` - never a public LoadBalancer/Ingress
   (org policy in `datadog-ese-sandbox`: no `0.0.0.0/0` firewall rules).
4. **Datadog agent.** `datadog/datadog-agent.yaml` replaces the stock `dd-agent`
   container with a Datadog Operator `DatadogAgent` CR, with **APM explicitly
   enabled** - required so Watchdog APM Faulty Deployment Detection has traces to
   analyze for the Deployment Gate.
5. **Unified Service Tagging** (`tags.datadoghq.com/{service,env,version}` labels +
   `DD_SERVICE`/`DD_ENV`/`DD_VERSION` env vars) is preserved on every workload.
   `DD_VERSION` is what Faulty Deployment Detection compares across releases.

## Apply order (manual - see repo root README for the ArgoCD-driven flow)

```bash
kubectl apply -f namespace.yaml
# secrets first (see argocd/install-notes.md for the imperative commands)
kubectl apply -f configmaps/ -n storedog
kubectl apply -f statefulsets/ -n storedog
kubectl apply -f deployments/ -n storedog
kubectl apply -f datadog/datadog-agent.yaml   # after the datadog-secret exists
# discounts is applied from ../rollouts/, not from here
```
