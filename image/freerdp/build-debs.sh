#!/bin/bash
# Build the FreeRDP packages of OpenThinRDP (see freerdp.conf). Needs Docker or Podman, ~6 GB of disk, and
# 15-40 minutes. The image build (FREERDP_FROM=openthinrdp) runs it on its own when the packages are missing.
# Usage: image/freerdp/build-debs.sh
# Result: out/freerdp/<commit>/*.deb (the packages a thin client needs), debug/*.deb (debug symbols), SHA256SUMS
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/freerdp.conf"
OUT=$ROOT/out/freerdp/$FREERDP_COMMIT
[ -f "$OUT/SHA256SUMS" ] && { echo "Already built: $OUT"; exit 0; }
ENGINE=$(command -v docker || command -v podman) || { echo "Docker or Podman needed"; exit 1; }
mkdir -p "$OUT"
"$ENGINE" run --rm -e FREERDP_REPO="$FREERDP_REPO" -e FREERDP_COMMIT="$FREERDP_COMMIT" \
  -e FREERDP_VERSION_BASE="$FREERDP_VERSION_BASE" -e FREERDP_OTR_REVISION="$FREERDP_OTR_REVISION" \
  -v "$HERE/inside-debs.sh":/inside-debs.sh:ro -v "$OUT":/out debian:trixie bash /inside-debs.sh
echo "Packages in $OUT"
