#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 1.0.0" >&2
  exit 64
fi

VERSION="${1#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 1.2.3 or 1.2.3-rc.1" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-tomaslejdung/clip-live-share-server}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"

if ! docker buildx version >/dev/null 2>&1; then
  echo "Docker Buildx is required." >&2
  exit 69
fi

echo "Publishing ${DOCKER_REPOSITORY}:${VERSION} for ${DOCKER_PLATFORMS}"
docker buildx build \
  --platform "$DOCKER_PLATFORMS" \
  --build-arg "VERSION=$VERSION" \
  --label "org.opencontainers.image.version=$VERSION" \
  --tag "${DOCKER_REPOSITORY}:${VERSION}" \
  --tag "${DOCKER_REPOSITORY}:latest" \
  --provenance=true \
  --sbom=true \
  --push \
  "$SERVER_ROOT"

echo "Published ${DOCKER_REPOSITORY}:${VERSION} and ${DOCKER_REPOSITORY}:latest"
