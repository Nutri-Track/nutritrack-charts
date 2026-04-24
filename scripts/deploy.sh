#!/bin/bash
# Deploy the NutriTrack stack from the repo-ready platform deployment repo.
# Usage: ./deploy.sh [namespace]

set -euo pipefail

NAMESPACE="${1:-nutritrack-dev}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLOBAL_VALUES="${PROJECT_ROOT}/values.yaml"
GATEWAY_NAME="${GATEWAY_NAME:-nutritrack-gateway}"

if [[ ! -f "${GLOBAL_VALUES}" ]]; then
  echo "Missing values file: ${GLOBAL_VALUES}" >&2
  exit 1
fi

echo "Deploying NutriTrack to Kubernetes"
echo "Namespace: ${NAMESPACE}"

echo ""
echo "Step 1: Create namespace"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "${NAMESPACE}" app.kubernetes.io/part-of=nutritrack app.kubernetes.io/managed-by=helm --overwrite
echo "Namespace ready"

echo ""
echo "Step 2: Apply plain Secret manifests"
kubectl apply -n "${NAMESPACE}" -f "${PROJECT_ROOT}/secrets"
echo "Secrets applied"

echo ""
echo "Step 3: Deploy PostgreSQL"
helm upgrade --install postgresql \
  "${PROJECT_ROOT}/infrastructure/postgresql" \
  -f "${GLOBAL_VALUES}" \
  --set global.namespace="${NAMESPACE}" \
  --set gateway.namespace="${NAMESPACE}" \
  -n "${NAMESPACE}" \
  --wait --timeout 120s
echo "PostgreSQL deployed"

echo ""
echo "Step 4: Wait for PostgreSQL"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=database -n "${NAMESPACE}" --timeout=120s
echo "PostgreSQL is ready"

echo ""
echo "Step 5: Deploy backend services"
BACKEND_SERVICES=(
  "auth-service"
  "food-service"
  "macro-service"
  "compliance-service"
)

for SERVICE in "${BACKEND_SERVICES[@]}"; do
  echo "  Deploying ${SERVICE}"
  helm upgrade --install "${SERVICE}" \
    "${PROJECT_ROOT}/microservices/${SERVICE}" \
    -f "${GLOBAL_VALUES}" \
    --set global.namespace="${NAMESPACE}" \
    --set gateway.namespace="${NAMESPACE}" \
    -n "${NAMESPACE}" \
    --wait --timeout 90s
  echo "  ${SERVICE} deployed"
done

echo ""
echo "Step 6: Deploy frontend"
helm upgrade --install frontend \
  "${PROJECT_ROOT}/microservices/frontend" \
  -f "${GLOBAL_VALUES}" \
  --set global.namespace="${NAMESPACE}" \
  --set gateway.namespace="${NAMESPACE}" \
  -n "${NAMESPACE}" \
  --wait --timeout 90s
echo "Frontend deployed"

echo ""
echo "Step 7: Deploy Envoy Gateway resources"
helm upgrade --install envoy-gateway \
  "${PROJECT_ROOT}/infrastructure/envoy-gateway" \
  -f "${GLOBAL_VALUES}" \
  --set global.namespace="${NAMESPACE}" \
  --set gateway.namespace="${NAMESPACE}" \
  --set gateway.name="${GATEWAY_NAME}" \
  -n "${NAMESPACE}" \
  --wait --timeout 90s
echo "Gateway resources deployed"

echo ""
echo "Deployment complete. Current workload status:"
kubectl get pods -n "${NAMESPACE}" -o wide
echo ""
kubectl get svc -n "${NAMESPACE}"
echo ""
echo "Find the Envoy Gateway service with:"
echo "kubectl get svc -n ${NAMESPACE} -l gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}"
