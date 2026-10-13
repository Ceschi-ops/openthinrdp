#!/bin/bash
# Signed software updates, from GitHub or from the management folder (UPDATE_FROM=github|share|off).
#   LATEST.txt       version=<version> / file=<package>.tar.gz / sha256=<hash>
#   LATEST.txt.sig   detached OpenPGP signature of LATEST.txt
#   <package>.tar.gz contains install.sh (+ files and .deb packages); management/publish/make-update.sh builds it
# Signatures accepted:
#   github  only the project key, /opt/openthinrdp/keys/openthinrdp-release.asc (in the image and the updates)
#   share   the project key (a release copied into the folder by the manager) or the key of the site,
#           /etc/openthinrdp/update-key.asc (your own packages, built into your image)
# "check <mounted folder>": run by report.sh every 5 minutes and at boot, with the folder mounted.
# "check-github": run by report.sh too, but asks GitHub at most every 3 hours (UPDATE_GITHUB = owner/repository,
# the latest release that is not a pre-release).
# A new version is downloaded, its hash checked, and installed in the background ("install <version>", unit
# openthinrdp-update). Never an older version than the installed one; at most 3 attempts per version.
. /opt/openthinrdp/lib/common.sh
PROJECT_KEY=$OTR/keys/openthinrdp-release.asc
SITE_KEY=$OTR_ETC/update-key.asc
W=$OTR_LIB/update
ST=$W/status
mkdir -p $W; chmod 700 $W

if [ "$1" = install ]; then
  V=$2; P=$W/pkg-$V; L=$OTR_LOG/update-$V.log
  [ -f "$P/install.sh" ] || { echo "ERROR $V: package not found" > $ST; exit 1; }
  echo "installing: $V (since $(date '+%d/%m %H:%M'))" > $ST
  ev "software update $V: installing"
  echo "2 $V" > /run/openthinrdp-update-progress   # percent and version, for the screens (ui.py)
  ( cd "$P" && timeout 1800 bash ./install.sh ) > "$L" 2>&1; rc=$?
  rm -f /run/openthinrdp-update-progress
  if [ $rc = 0 ]; then
    echo "$V" > "$OTR_LIB/update-version"
    echo "up to date: $V ($(date '+%d/%m %H:%M'))" > $ST
    ev "software update $V installed"
    rm -rf "$P" "$W"/*.tar.gz "$W"/attempts-*
  else
    echo "ERROR $V: install failed (code $rc, attempt $(cat "$W/attempts-$V" 2>/dev/null)/3, log $L)" > $ST
    ev "software update $V FAILED (code $rc): $(grep -v '^$' "$L" | tail -1 | cut -c1-150)"
  fi
  # Shut down was pressed during the install (kiosk.sh waits for it): switch off now that it is recorded
  # (the file says poweroff or reboot)
  if [ -f /tmp/openthinrdp-poweroff-pending ]; then
    a=$(cat /tmp/openthinrdp-poweroff-pending); [ "$a" = reboot ] || a=poweroff
    ev "$a after the software update"; systemctl --no-block "$a"
  fi
  exit $rc
fi

# get NAME DEST: one file of the update source (management folder or GitHub release)
get(){
  if [ "$SRC" = share ]; then cp "$D/$1" "$2" 2>/dev/null
  else
    # python3 is in the image, curl is not; GitHub answers with a redirect, which urllib follows.
    # Exit 3 = the server answered with an error (e.g. 404, no release yet), 1 = no answer at all
    python3 - "$BASE/$1" "$2" <<'PY' 2>/dev/null
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], "wb") as f:
        while True:
            b = r.read(1 << 16)
            if not b: break
            f.write(b)
except urllib.error.HTTPError:
    sys.exit(3)
except Exception:
    sys.exit(1)
PY
  fi
}
# verify SIG FILE: sqv ships with Debian 13 (apt uses it); gpgv only if sqv is missing
verify(){
  local k a=()
  for k in "${KEYS[@]}"; do [ -s "$k" ] && a+=(--keyring "$k"); done
  [ ${#a[@]} -gt 0 ] || return 1
  if command -v sqv >/dev/null; then sqv "${a[@]}" "$1" "$2" >/dev/null 2>&1
  elif command -v gpgv >/dev/null; then gpgv "${a[@]}" "$1" "$2" >/dev/null 2>&1; else return 1; fi
}

case "$1" in
  check)
    SRC=share; D="$2/updates"; KEYS=("$PROJECT_KEY" "$SITE_KEY")
    [ -f "$D/LATEST.txt" ] || { echo "no update published in the management folder" > $ST; exit 0; } ;;
  check-github)
    SRC=github; KEYS=("$PROJECT_KEY")
    REPO=$(cfg UPDATE_GITHUB)
    BASE=${OTR_UPDATE_BASE_URL:-https://github.com/$REPO/releases/latest/download}
    # at most every 3 hours once GitHub answered (report.sh runs every 5 minutes: without network, e.g. right
    # after boot, it simply tries again at the next run)
    [ -f $W/github-checked ] && [ $(( $(date +%s) - $(stat -c %Y $W/github-checked) )) -lt 10800 ] && exit 0 ;;
  *) echo "usage: $0 check <mounted folder> | check-github | install <version>"; exit 2 ;;
esac
[ -s "${KEYS[0]}" ] || [ -s "${KEYS[1]:-}" ] || { echo "updates disabled: no signing key" > $ST; exit 0; }
systemctl is-active -q openthinrdp-update.service 2>/dev/null && exit 0      # an install is already running
rm -f $W/LATEST.txt $W/LATEST.txt.sig
get LATEST.txt $W/LATEST.txt; rc=$?
# GitHub answered (also "no release yet"): next question in 3 hours. No answer: at the next run
[ $SRC = github ] && { [ $rc = 0 ] || [ $rc = 3 ]; } && touch $W/github-checked
if [ $rc != 0 ]; then
  echo "no update found ($SRC$([ $SRC = github ] && echo " $REPO$([ $rc = 1 ] && echo ', not reachable')"), $(date '+%d/%m %H:%M'))" > $ST; exit 0; fi
get LATEST.txt.sig $W/LATEST.txt.sig || : > $W/LATEST.txt.sig
if ! verify $W/LATEST.txt.sig $W/LATEST.txt; then
  S=$(md5sum < $W/LATEST.txt | cut -c1-32)
  [ "$(cat $W/bad-signature 2>/dev/null)" = "$S" ] || { ev "update from $SRC with an INVALID signature: ignored"; echo "$S" > $W/bad-signature; }
  echo "IGNORED: invalid signature on LATEST.txt ($SRC)" > $ST; exit 0
fi
V=$(sed -n 's/^version=//p' $W/LATEST.txt | tr -d '\r' | head -1)
F=$(sed -n 's/^file=//p' $W/LATEST.txt | tr -d '\r' | head -1)
H=$(sed -n 's/^sha256=//p' $W/LATEST.txt | tr -d '\r' | head -1)
{ [[ $V =~ ^[0-9A-Za-z._-]+$ ]] && [[ $F =~ ^[0-9A-Za-z._-]+\.tar\.gz$ ]] && [[ $H =~ ^[0-9a-f]{64}$ ]]; } || { echo "IGNORED: LATEST.txt not valid" > $ST; exit 0; }
# the version installed: the last update, or the image itself when no update was ever installed
CUR=$(cat "$OTR_LIB/update-version" 2>/dev/null || cat "$OTR/VERSION" 2>/dev/null)
[ "$V" = "$CUR" ] && { echo "up to date: $V ($SRC, $(date '+%d/%m %H:%M'))" > $ST; exit 0; }
if [ -n "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$V" | sort -V | tail -1)" = "$CUR" ]; then
  echo "up to date: $CUR ($SRC has $V, older: ignored)" > $ST; exit 0; fi
N=$(cat "$W/attempts-$V" 2>/dev/null || echo 0)
[ "$N" -ge 3 ] && { echo "ERROR $V: 3 failed attempts, not retrying (log $OTR_LOG/update-$V.log)" > $ST; exit 0; }
# at least 10 minutes between attempts: every event line starts report.sh, and without this pause the 3
# attempts burned out in seconds (e.g. on a freshly installed device with apt busy)
if [ "$N" -ge 1 ] && [ $(( $(date +%s) - $(stat -c %Y "$W/attempts-$V" 2>/dev/null || echo 0) )) -lt 600 ]; then exit 0; fi
get "$F" "$W/$F.part" || { rm -f "$W/$F.part"; echo "ERROR $V: download of $F failed ($SRC)" > $ST; exit 0; }
if [ "$(sha256sum < "$W/$F.part" | cut -c1-64)" != "$H" ]; then
  rm -f "$W/$F.part"; echo "ERROR $V: package hash differs from LATEST.txt (incomplete copy?)" > $ST; exit 0; fi
mv -f "$W/$F.part" "$W/$F"
rm -rf "$W/pkg-$V"; mkdir -p "$W/pkg-$V"
tar -xzf "$W/$F" -C "$W/pkg-$V" || { echo "ERROR $V: package cannot be extracted" > $ST; exit 0; }
echo $((N + 1)) > "$W/attempts-$V"
echo "found $V ($SRC): install started" > $ST
systemd-run --unit=openthinrdp-update --collect --no-block --property=Nice=10 "$OTR/auto-update.sh" install "$V" >/dev/null 2>&1
exit 0
