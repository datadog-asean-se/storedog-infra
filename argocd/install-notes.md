# ArgoCD + Argo Rollouts install

## 1. ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server

# Access the UI WITHOUT a public LoadBalancer (org policy: no 0.0.0.0/0 firewall rules):
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
# initial admin password:
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 2. Argo Rollouts controller

Install this **before** the `storedog-rollouts` Application, or ArgoCD will fail to
sync the `Rollout` CRD with a "no matches for kind Rollout" error.

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts

# optional but recommended: kubectl plugin for `kubectl argo rollouts get rollout ...`
brew install argoproj/tap/kubectl-argo-rollouts   # or see Argo Rollouts docs for your OS
```

## 3. Datadog secrets (imperative - never commit these)

```bash
kubectl create namespace datadog
kubectl -n datadog create secret generic datadog-secret \
  --from-literal api-key="$DD_API_KEY" --from-literal app-key="$DD_APP_KEY"

kubectl create namespace storedog
kubectl -n storedog create secret generic storedog-secrets \
  --from-literal POSTGRES_PASSWORD='<choose-a-password>' \
  --from-literal DB_PASSWORD='<choose-a-password>'
kubectl -n storedog create secret generic datadog-secret \
  --from-literal dd_application_id="$NEXT_PUBLIC_DD_APPLICATION_ID" \
  --from-literal dd_client_token="$NEXT_PUBLIC_DD_CLIENT_TOKEN"
kubectl -n storedog create secret generic datadog-ci-keys \
  --from-literal DD_API_KEY="$DD_API_KEY" --from-literal DD_APP_KEY="$DD_APP_KEY"
```

## 4. Install the Datadog Operator (Helm, not ArgoCD-managed)

```bash
helm repo add datadog https://helm.datadoghq.com && helm repo update
helm install datadog-operator datadog/datadog-operator -n datadog
```

## 5. Register the two Applications (GitOps)

```bash
kubectl apply -f app-storedog.yaml            # namespace, config, agent CR, base app
kubectl apply -f app-storedog-rollouts.yaml   # discounts Rollout + Deployment Gate
```

If you forked this repo instead of pushing directly to
`datadog-asean-se/storedog-infra`, edit `spec.source.repoURL` in both files first.

Watch the sync:

```bash
kubectl get applications -n argocd
kubectl -n storedog get pods -w
```

The demo trigger scripts (`../scripts/rollout-bad.sh` / `rollout-good.sh`) work by
editing `rollouts/discounts-rollout.yaml` in a checkout of **this same repo** and
pushing; ArgoCD auto-syncs and Argo Rollouts performs the canary + Deployment Gate
analysis.
