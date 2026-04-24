#!/bin/bash
# Build Docker images from sibling repo-ready service folders.
# Usage: ./build-images.sh [registry] [tag]

set -euo pipefail

REGISTRY="${1:-nutritrack360}"
TAG="${2:-latest}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_READY_ROOT="$(cd "${PROJECT_ROOT}/.." && pwd)"

echo "Building Docker images"
echo "Registry: ${REGISTRY}"
echo "Tag: ${TAG}"

SERVICES=(
  "auth-service"
  "food-service"
  "macro-service"
  "compliance-service"
  "frontend"
)

for SERVICE in "${SERVICES[@]}"; do
  CONTEXT_DIR="${REPO_READY_ROOT}/${SERVICE}"
  if [[ ! -d "${CONTEXT_DIR}" ]]; then
    echo "Missing build context: ${CONTEXT_DIR}" >&2
    exit 1
  fi

  echo ""
  echo "Building ${SERVICE}"
  docker build \
    -t "${REGISTRY}/${SERVICE}:${TAG}" \
    -t "${REGISTRY}/${SERVICE}:latest" \
    "${CONTEXT_DIR}"
  echo "${SERVICE} built successfully"
done

echo ""
echo "All images built successfully."
