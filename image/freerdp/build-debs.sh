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
# one archive to attach to a release (package names have "~" and "+", which release asset names do not keep)
TAR=openthinrdp-freerdp-${FREERDP_COMMIT:0:9}.tar
(cd "$OUT" && tar -cf "../$TAR" *.deb SHA256SUMS)
echo "Packages in $OUT, release archive out/freerdp/$TAR"
echo "Its line for image/freerdp/SHA256SUMS: $(cd "$OUT/.." && sha256sum "$TAR")"
