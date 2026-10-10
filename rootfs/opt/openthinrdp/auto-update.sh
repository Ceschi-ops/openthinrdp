#!/bin/bash
# Signed updates from the management folder, updates\ :
#   LATEST.txt       version=<version> / file=<package>.tar.gz / sha256=<hash>
#   LATEST.txt.sig   detached OpenPGP signature of LATEST.txt: ONLY packages signed with the key in
#                    /etc/openthinrdp/update-key.asc (built into the image) are installed
#   <package>.tar.gz contains install.sh (+ files and .deb packages); management/publish/ builds it
# "check <mounted folder>": run by report.sh every 5 minutes and at boot. A new version is copied, its hash
# checked, and installed in the background ("install <version>", unit openthinrdp-update).
# Never an older version than the installed one; at most 3 attempts per version.
. /opt/openthinrdp/lib/common.sh
K=$OTR_ETC/update-key.asc
W=$OTR_LIB/update
ST=$W/status
mkdir -p $W; chmod 700 $W

if [ "$1" = install ]; then
  V=$2; P=$W/pkg-$V; L=$OTR_LOG/update-$V.log
  [ -f "$P/install.sh" ] || { echo "ERROR $V: package not found" > $ST; exit 1; }
  echo "installing: $V (since $(date '+%d/%m %H:%M'))" > $ST
  ev "software update $V: installing"
  ( cd "$P" && timeout 1800 bash ./install.sh ) > "$L" 2>&1; rc=$?
  if [ $rc = 0 ]; then
    echo "$V" > "$OTR_LIB/update-version"
    echo "up to date: $V ($(date '+%d/%m %H:%M'))" > $ST
    ev "software update $V installed"
    rm -rf "$P" "$W"/*.tar.gz "$W"/attempts-*
  else
    echo "ERROR $V: install failed (code $rc, attempt $(cat "$W/attempts-$V" 2>/dev/null)/3, log $L)" > $ST
    ev "software update $V FAILED (code $rc): $(grep -v '^$' "$L" | tail -1 | cut -c1-150)"
  fi
  exit $rc
fi

[ "$1" = check ] || { echo "usage: $0 check <mounted folder> | install <version>"; exit 2; }
D="$2/updates"
[ -f "$D/LATEST.txt" ] || { echo "no update published" > $ST; exit 0; }
[ -s "$K" ] || { echo "updates disabled: no signing key in $K" > $ST; exit 0; }
systemctl is-active -q openthinrdp-update.service && exit 0      # an install is already running
cp "$D/LATEST.txt" $W/LATEST.txt; cp "$D/LATEST.txt.sig" $W/LATEST.txt.sig 2>/dev/null || : > $W/LATEST.txt.sig
# sqv ships with Debian 13 (apt uses it); gpgv only if sqv is missing
verify(){ if command -v sqv >/dev/null; then sqv --keyring "$K" "$1" "$2" >/dev/null 2>&1
          elif command -v gpgv >/dev/null; then gpgv --keyring "$K" "$1" "$2" >/dev/null 2>&1; else return 1; fi; }
if ! verify $W/LATEST.txt.sig $W/LATEST.txt; then
  S=$(md5sum < $W/LATEST.txt | cut -c1-32)
  [ "$(cat $W/bad-signature 2>/dev/null)" = "$S" ] || { ev "update in the management folder with an INVALID signature: ignored"; echo "$S" > $W/bad-signature; }
  echo "IGNORED: invalid signature on LATEST.txt" > $ST; exit 0
fi
V=$(sed -n 's/^version=//p' $W/LATEST.txt | tr -d '\r' | head -1)
F=$(sed -n 's/^file=//p' $W/LATEST.txt | tr -d '\r' | head -1)
H=$(sed -n 's/^sha256=//p' $W/LATEST.txt | tr -d '\r' | head -1)
{ [[ $V =~ ^[0-9A-Za-z._-]+$ ]] && [[ $F =~ ^[0-9A-Za-z._-]+\.tar\.gz$ ]] && [[ $H =~ ^[0-9a-f]{64}$ ]]; } || { echo "IGNORED: LATEST.txt not valid" > $ST; exit 0; }
CUR=$(cat "$OTR_LIB/update-version" 2>/dev/null)
[ "$V" = "$CUR" ] && { echo "up to date: $V" > $ST; exit 0; }
if [ -n "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$V" | sort -V | tail -1)" = "$CUR" ]; then
  echo "up to date: $CUR (the folder has $V, older: ignored)" > $ST; exit 0; fi
N=$(cat "$W/attempts-$V" 2>/dev/null || echo 0)
[ "$N" -ge 3 ] && { echo "ERROR $V: 3 failed attempts, not retrying (log $OTR_LOG/update-$V.log)" > $ST; exit 0; }
# at least 10 minutes between attempts: every event line starts report.sh, and without this pause the 3
# attempts burned out in seconds (e.g. on a freshly installed device with apt busy)
if [ "$N" -ge 1 ] && [ $(( $(date +%s) - $(stat -c %Y "$W/attempts-$V" 2>/dev/null || echo 0) )) -lt 600 ]; then exit 0; fi
cp "$D/$F" "$W/$F.part" 2>/dev/null || { echo "ERROR $V: copy of $F failed" > $ST; exit 0; }
if [ "$(sha256sum < "$W/$F.part" | cut -c1-64)" != "$H" ]; then
  rm -f "$W/$F.part"; echo "ERROR $V: package hash differs from LATEST.txt (incomplete copy?)" > $ST; exit 0; fi
mv -f "$W/$F.part" "$W/$F"
rm -rf "$W/pkg-$V"; mkdir -p "$W/pkg-$V"
tar -xzf "$W/$F" -C "$W/pkg-$V" || { echo "ERROR $V: package cannot be extracted" > $ST; exit 0; }
echo $((N + 1)) > "$W/attempts-$V"
echo "found $V: install started" > $ST
systemd-run --unit=openthinrdp-update --collect --no-block --property=Nice=10 "$OTR/auto-update.sh" install "$V" >/dev/null 2>&1
exit 0
