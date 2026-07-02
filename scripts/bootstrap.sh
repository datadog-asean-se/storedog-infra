#!/usr/bin/env bash
# End-to-end bootstrap: ephemeral GKE -> ArgoCD -> Argo Rollouts -> Datadog Operator
# -> storedog (via ArgoCD). Intended to be read alongside the root README.md, not
# run blindly - each step is echoed so you can follow along or run them by hand.
#
# Required env vars: DD_API_KEY, DD_APP_KEY
# Optional: NEXT_PUBLIC_DD_APPLICATION_ID, NEXT_PUBLIC_DD_CLIENT_TOKEN (RUM)
#           POSTGRES_PASSWORD (defaults to a generated value if unset)
set -euo pipefail

: "${DD_API_KEY:?export DD_API_KEY first}"
: "${DD_APP_KEY:?export DD_APP_KEY first}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -hex 12)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== 1/7  Terraform: ephemeral GKE cluster =="
( cd "$ROOT/terraform" && terraform init -upgrade && terraform apply -auto-approve )

echo "== 2/7  kubectl via DNS endpoint =="
eval "$(cd "$ROOT/terraform" && terraform output -raw get_credentials_command)"

echo "== 3/7  ArgoCD =="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo "== 4/7  Argo Rollouts controller =="
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=180s

echo "== 5/7  Datadog Operator (Helm) + secrets =="
helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
kubectl -n datadog create secret generic datadog-secret \
  --from-literal api-key="$DD_API_KEY" --from-literal app-key="$DD_APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install datadog-operator datadog/datadog-operator -n datadog

kubectl create namespace storedog --dry-run=client -o yaml | kubectl apply -f -
kubectl -n storedog create secret generic storedog-secrets \
  --from-literal POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal DB_PASSWORD="$POSTGRES_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n storedog create secret generic datadog-secret \
  --from-literal dd_application_id="${NEXT_PUBLIC_DD_APPLICATION_ID:-not-set}" \
  --from-literal dd_client_token="${NEXT_PUBLIC_DD_CLIENT_TOKEN:-not-set}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n storedog create secret generic datadog-ci-keys \
  --from-literal DD_API_KEY="$DD_API_KEY" --from-literal DD_APP_KEY="$DD_APP_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== 6/7  Register the storedog ArgoCD Applications =="
kubectl apply -f "$ROOT/argocd/app-storedog.yaml"
kubectl apply -f "$ROOT/argocd/app-storedog-rollouts.yaml"

echo "== 7/7  Done. Watch rollout with: =="
echo "  kubectl -n storedog get pods -w"
echo "Reach the storefront with: $ROOT/scripts/port-forward.sh"
