#!/bin/bash

# Reviewed Sparkle dependency identity used by project auditing, clean release
# resolution, and artifact provenance. Keep these values in sync with the exact
# Swift Package Manager pin in the Xcode project and Package.resolved.

CLIP_SPARKLE_VERSION="2.9.4"
CLIP_SPARKLE_REVISION="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
CLIP_SPARKLE_REPOSITORY_URL="https://github.com/sparkle-project/Sparkle"
CLIP_SPARKLE_ARTIFACT_CHECKSUM="cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"

export \
  CLIP_SPARKLE_VERSION \
  CLIP_SPARKLE_REVISION \
  CLIP_SPARKLE_REPOSITORY_URL \
  CLIP_SPARKLE_ARTIFACT_CHECKSUM
