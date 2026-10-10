#!/bin/bash
# Build the OpenThinRDP installer ISO. Needs Docker or Podman (privileged containers) and ~15 GB of disk.
# Usage: image/build.sh [site folder]    default: image/site, or image/site.example if it does not exist
# Result: out/openthinrdp-<version>.iso (+ .sha256)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
SITE=${1:-$HERE/site}; [ -d "$SITE" ] || { echo "No $SITE: building with image/site.example"; SITE=$HERE/site.example; }
[ -f "$SITE/build.conf" ] || { echo "$SITE/build.conf missing"; exit 1; }
ENGINE=$(command -v docker || command -v podman) || { echo "Docker or Podman needed"; exit 1; }
mkdir -p "$ROOT/out"
"$ENGINE" run --rm --privileged \
  -v "$ROOT/rootfs":/build/rootfs:ro -v "$HERE":/build/image:ro -v "$SITE":/build/site:ro \
  -v "$ROOT/VERSION":/build/VERSION:ro -v "$ROOT/out":/out \
  debian:trixie bash /build/image/lb/inside.sh
