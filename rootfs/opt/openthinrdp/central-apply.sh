#!/bin/bash
# Central settings: config\common.conf (every device) and config\<hostname>.conf (one device) in the
# management folder. report.sh copies them to $OTR_LIB; here they are merged over the current settings,
# validated by save-config.sh and applied ONLY when something changes. Folder unreachable = the last
# copies are used (last good configuration).
# The comparison uses save-config.sh --print on both sides: the values are compared in the form they are
# stored in, so "Static" and "static", or "1EAF:0009,x" and "1eaf:0009 x", are not seen as changes (a false
# difference would re-apply everything every 5 minutes).
. /opt/openthinrdp/lib/common.sh
ST=$OTR_LIB/central-status
COMMON=$OTR_LIB/central-common.conf
HOSTF=$OTR_LIB/central-host.conf
# keys that only the file of a single device may set (they identify the device)
HOST_ONLY="HOSTNAME DEFAULT_USER NETMODE IPADDR"
KEYS="$(cfg_keys | tr '\n' ' ')WIFI_PSK"

[ -f "$COMMON" ] || [ -f "$HOSTF" ] || { echo "no central configuration" > "$ST"; exit 0; }

# files written on Windows: CRLF, BOM, spaces around "=", comments with # or ;
read_conf(){ sed '1s/^\xEF\xBB\xBF//' "$1" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]*=[[:space:]]*/=/; s/[[:space:]]+$//' | grep -E '^[A-Z][A-Z0-9_]*='; }
declare -A GIVEN
merge(){ local f=$1 scope=$2 line k
  [ -f "$f" ] || return
  while IFS= read -r line; do k=${line%%=*}
    [[ " $KEYS " == *" $k "* ]] || continue
    [ "$scope" = common ] && [[ " $HOST_ONLY " == *" $k "* ]] && continue
    GIVEN[$k]=${line#*=}
  done < <(read_conf "$f"); }
merge "$COMMON" common
merge "$HOSTF" host

T=$(mktemp); E=$(mktemp); chmod 600 "$T" "$E"; trap 'rm -f "$T" "$E"' EXIT
# current settings, stored form
: > "$E"
declare -A CUR NEW
while IFS= read -r line; do CUR[${line%%=*}]=${line#*=}; done < <("$OTR/save-config.sh" "$E" --print 2>/dev/null)
# central values over the current ones, stored form (a rejection stops here)
for k in "${!GIVEN[@]}"; do echo "$k=${GIVEN[$k]}"; done > "$T"
if ! OUTN=$("$OTR/save-config.sh" "$T" --print 2>&1); then MSG=$OUTN; DIFF="(invalid)"
else
  while IFS= read -r line; do NEW[${line%%=*}]=${line#*=}; done <<< "$OUTN"
  DIFF=""
  for k in $KEYS; do [ "${NEW[$k]}" != "${CUR[$k]}" ] && DIFF="$DIFF $k"; done
  if [ -z "$DIFF" ]; then echo "in line $(date '+%Y-%m-%d %H:%M')" > "$ST"; rm -f "$OTR_LIB/central-rejected"; exit 0; fi
  # only the keys that differ go to save-config: the others keep following site.conf and the defaults
  for k in $DIFF; do echo "$k=${NEW[$k]}"; done > "$T"
  MSG=$("$OTR/save-config.sh" "$T" 2>&1) && {
    ev "central configuration applied:${DIFF/ WIFI_PSK/ WIFI_PSK(hidden)}"
    echo "applied $(date '+%Y-%m-%d %H:%M'):$DIFF" > "$ST"
    rm -f "$OTR_LIB/central-rejected"
    exit 0; }
fi
# the same wrong configuration is reported once, not every 5 minutes
SIG=$(cat "$COMMON" "$HOSTF" 2>/dev/null | md5sum | cut -c1-32)
if [ "$(cat "$OTR_LIB/central-rejected" 2>/dev/null)" != "$SIG" ]; then
  ev "central configuration REJECTED (the previous one stays): $(echo "$MSG" | tr '\n' ' ')"
  echo "$SIG" > "$OTR_LIB/central-rejected"
fi
echo "REJECTED $(date '+%Y-%m-%d %H:%M'): $(echo "$MSG" | tr '\n' ' ' | cut -c1-120)" > "$ST"
exit 0
