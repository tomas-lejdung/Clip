#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <version> [--latest]" >&2
  echo "Example: $0 1.4.0-server.1" >&2
  echo "Stable release: $0 1.4.0 --latest" >&2
  exit 64
fi

VERSION="${1#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Version must look like 1.2.3 or 1.2.3-rc.1" >&2
  exit 64
fi

PUBLISH_LATEST=false
if [[ $# -eq 2 ]]; then
  if [[ "$2" != "--latest" ]]; then
    echo "The only supported option is --latest." >&2
    exit 64
  fi
  PUBLISH_LATEST=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKER_REPOSITORY="${DOCKER_REPOSITORY:-tomaslejdung/clip-live-share-server}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
IMAGE_REFERENCE="${DOCKER_REPOSITORY}:${VERSION}"
REPOSITORY_ROOT="$(cd "$SERVER_ROOT/.." && pwd)"

if ! docker buildx version >/dev/null 2>&1; then
  echo "Docker Buildx is required." >&2
  exit 69
fi

if docker buildx imagetools inspect "$IMAGE_REFERENCE" >/dev/null 2>&1; then
  echo "Refusing to overwrite existing immutable tag ${IMAGE_REFERENCE}." >&2
  exit 65
fi

SERVER_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain -- server)"
if [[ -n "$SERVER_STATUS" && "${ALLOW_DIRTY_SERVER:-0}" != "1" ]]; then
  echo "The server source is dirty; commit it before publishing." >&2
  echo "For an intentional test image, set ALLOW_DIRTY_SERVER=1." >&2
  exit 65
fi

REVISION="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
if [[ -n "$SERVER_STATUS" ]]; then
  REVISION="${REVISION}-dirty"
fi

echo "Running server tests"
(
  cd "$SERVER_ROOT"
  go test ./...
  go test -race ./...
)

TAGS=(--tag "$IMAGE_REFERENCE")
if [[ "$PUBLISH_LATEST" == true ]]; then
  TAGS+=(--tag "${DOCKER_REPOSITORY}:latest")
fi

echo "Publishing ${IMAGE_REFERENCE} for ${DOCKER_PLATFORMS}"
docker buildx build \
  --platform "$DOCKER_PLATFORMS" \
  --build-arg "VERSION=$VERSION" \
  --label "org.opencontainers.image.version=$VERSION" \
  --label "org.opencontainers.image.revision=$REVISION" \
  "${TAGS[@]}" \
  --provenance=true \
  --sbom=true \
  --push \
  "$SERVER_ROOT"

docker buildx imagetools inspect "$IMAGE_REFERENCE"

echo "Published ${IMAGE_REFERENCE}"
if [[ "$PUBLISH_LATEST" == true ]]; then
  echo "Updated ${DOCKER_REPOSITORY}:latest"
else
  echo "Left ${DOCKER_REPOSITORY}:latest unchanged"
fi
