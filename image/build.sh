#!/bin/bash
# Build the OpenThinRDP installer ISO. Needs Docker or Podman (privileged containers) and ~15 GB of disk.
# Usage: image/build.sh [site folder]    default: image/site, or image/site.example if it does not exist
# Result: out/openthinrdp-<version>.iso (+ .sha256)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
SITE=${1:-$HERE/site}; [ -d "$SITE" ] || { echo "No $SITE: building with image/site.example"; SITE=$HERE/site.example; }
[ -f "$SITE/build.conf" ] || { echo "$SITE/build.conf missing"; exit 1; }
ENGINE=$(command -v docker || command -v podman) || { echo "Docker or Podman needed"; exit 1; }
# out/cache keeps the downloaded packages between builds: rebuilds take a fraction of the time
mkdir -p "$ROOT/out/cache"
# FREERDP_FROM=openthinrdp (default): FreeRDP with UDP, see image/freerdp/freerdp.conf. The prebuilt packages
# of the release (one archive, checked against image/freerdp/SHA256SUMS); without that file, or when the
# download fails, they are built here.
if [ "$(sed -n 's/^FREERDP_FROM=//p' "$SITE/build.conf" | tail -1)" = openthinrdp ]; then
  . "$HERE/freerdp/freerdp.conf"
  FD=$ROOT/out/freerdp/$FREERDP_COMMIT
  if [ ! -f "$FD/SHA256SUMS" ] && [ -s "$HERE/freerdp/SHA256SUMS" ]; then
    TAR=$(awk '{print $2}' "$HERE/freerdp/SHA256SUMS")
    echo "Downloading the FreeRDP packages: $FREERDP_RELEASE_URL/$TAR"
    rm -rf "$FD.part"; mkdir -p "$FD.part"
    if curl -fsSL -o "$FD.part/$TAR" "$FREERDP_RELEASE_URL/$TAR" \
       && (cd "$FD.part" && sha256sum -c --quiet "$HERE/freerdp/SHA256SUMS" && tar -xf "$TAR" && rm "$TAR" && sha256sum -c --quiet SHA256SUMS); then
      rm -rf "$FD"; mv "$FD.part" "$FD"
    else echo "Download failed or the archive does not match SHA256SUMS: building the packages"; rm -rf "$FD.part"; fi
  fi
  [ -f "$FD/SHA256SUMS" ] || "$HERE/freerdp/build-debs.sh"
fi
"$ENGINE" run --rm --privileged \
  -v "$ROOT/rootfs":/build/rootfs:ro -v "$HERE":/build/image:ro -v "$SITE":/build/site:ro \
  -v "$ROOT/VERSION":/build/VERSION:ro -v "$ROOT/out":/out -v "$ROOT/out/cache":/lb/cache \
  debian:trixie bash /build/image/lb/inside.sh
