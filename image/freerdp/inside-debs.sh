#!/bin/bash
# Runs inside a debian:trixie container (build-debs.sh): FreeRDP source at FREERDP_COMMIT + the Debian
# packaging of trixie-backports, UDP on, binary packages only.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive DEBEMAIL=noreply@openthinrdp.invalid DEBFULLNAME=OpenThinRDP
printf 'deb http://deb.debian.org/debian trixie-backports main\ndeb-src http://deb.debian.org/debian trixie-backports main\n' \
  > /etc/apt/sources.list.d/backports.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates git devscripts build-essential patch >/dev/null
apt-get build-dep -y -qq -t trixie-backports freerdp3 >/dev/null
mkdir -p /b && cd /b
apt-get source -qq -t trixie-backports freerdp3
DEB=$(ls -d /b/freerdp3-*/ | head -1)
git init -q /b/src && cd /b/src
git fetch -q --depth 1 "$FREERDP_REPO" "$FREERDP_COMMIT" && git checkout -q FETCH_HEAD
DATE=$(git log -1 --format=%cs | tr -d -); SHORT=$(git rev-parse --short=9 HEAD)
cp -a "$DEB/debian" .
# Debian's own patches are written for its release: those that no longer apply to the newer source are skipped
if [ -f debian/patches/series ]; then
  for p in $(grep -v '^#' debian/patches/series); do
    if patch -p1 --dry-run -s < "debian/patches/$p" >/dev/null 2>&1; then patch -p1 -s < "debian/patches/$p"; echo "Debian patch applied: $p"
    else echo "Debian patch skipped (does not apply to this source): $p"; fi
  done
  : > debian/patches/series
fi
sed -i '0,/dh_auto_configure --/s//dh_auto_configure -- -DWITH_RDPEUDP=ON/' debian/rules
grep -q WITH_RDPEUDP=ON debian/rules || { echo "debian/rules: could not turn UDP on"; exit 1; }
V="$FREERDP_VERSION_BASE.$DATE.$SHORT+otr$FREERDP_OTR_REVISION"
dch -b -v "$V" -D trixie-backports "OpenThinRDP: FreeRDP $FREERDP_COMMIT with the UDP transport (RDPEUDP)" </dev/null
# the UDP code exports functions Debian's symbol files do not know yet: they only matter for a distribution
rm -f debian/*.symbols
DPKG_GENSYMBOLS_CHECK_LEVEL=0 DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -us -uc -d > /b/build.log 2>&1 \
  || { grep -nE 'error|Error' /b/build.log | head -30; tail -30 /b/build.log; exit 1; }
# a thin client needs the X11 client and its libraries; debug symbols apart, for whoever has to debug a crash
cd /b
mkdir -p /out/debug
for p in freerdp3-x11 freerdp-x11 libfreerdp3-3 libfreerdp-client3-3 libwinpr3-3; do cp ${p}_*.deb /out/; done
for p in freerdp-x11 libfreerdp3-3 libfreerdp-client3-3 libwinpr3-3; do cp ${p}-dbgsym_*.deb /out/debug/ 2>/dev/null || true; done
cd /out && sha256sum *.deb > SHA256SUMS && cat SHA256SUMS
dpkg-deb -I freerdp-x11_*.deb | grep -E 'Version|Depends'
