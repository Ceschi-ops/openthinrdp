#!/bin/bash
# OpenThinRDP tests that need no hardware: settings layers, validation, central configuration, status file.
# Runs as root inside a throw-away Debian 13 container (it installs the rootfs into /):
#   docker run --rm -v "$PWD":/src:ro debian:trixie bash /src/tests/run-tests.sh
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq wpasupplicant iproute2 procps systemd >/dev/null 2>&1
cp -a /src/rootfs/. /
OTR=/opt/openthinrdp
chmod 755 $OTR/*.sh
# the system side is not under test here: apply, browser policy and schedule become no-ops
for s in apply.sh browser-policy.sh schedule.sh; do printf '#!/bin/bash\nexit 0\n' > $OTR/$s; done
mkdir -p /etc/openthinrdp /var/lib/openthinrdp /var/log/openthinrdp; touch /var/log/openthinrdp/events.log
. $OTR/lib/common.sh
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
T=$(mktemp)

# --- layers: device > site > defaults
ok "default when nothing set" '[ "$(cfg TRANSPORT)" = auto ]'
printf 'TRANSPORT=udp\nTITLE=Site title\n' > /etc/openthinrdp/site.conf
ok "site overrides default" '[ "$(cfg TRANSPORT)" = udp ]'
printf 'TRANSPORT=tcp\n' > /etc/openthinrdp/openthinrdp.conf
ok "device overrides site" '[ "$(cfg TRANSPORT)" = tcp ]'
printf 'TITLE=\n' >> /etc/openthinrdp/openthinrdp.conf
ok "empty device value clears the site value" '[ -z "$(cfg TITLE)" ]'
: > /etc/openthinrdp/openthinrdp.conf; : > /etc/openthinrdp/site.conf
ok "cfg_num falls back on garbage" '[ "$(printf "SHUTDOWN_SECS=abc\n" > /etc/openthinrdp/openthinrdp.conf; cfg_num SHUTDOWN_SECS 10)" = 10 ]'
: > /etc/openthinrdp/openthinrdp.conf

# --- validation (save-config.sh --print changes nothing)
check(){ printf '%s\n' "$2" > "$T"; $OTR/save-config.sh "$T" --print >/dev/null 2>&1; }
ok "empty input is valid with defaults" 'check x ""'
ok "hostname only digits refused" '! check x "HOSTNAME=12345"'
ok "good hostname" 'check x "HOSTNAME=reception-1"'
ok "static without DNS refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1")"'
ok "static gateway in another network refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=198.51.100.1\nDNS1=192.0.2.53")"'
ok "good static" 'check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53")"'
ok "bad netmask refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.0.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53")"'
ok "share with one backslash refused" '! check x "MGMT_SHARE=\\fileserver\\thinclients"'
ok "good share" 'check x "MGMT_SHARE=\\\\fileserver\\thinclients"'
ok "app button without URL refused" '! check x "WEB_BUTTON=app"'
ok "kiosk without page refused" '! check x "WEB_BUTTON=kiosk"'
ok "URL with a quote refused" '! check x "WEB_URL=https://example.com/a\"b"'
ok "title with markup refused" '! check x "TITLE=<b>x</b>"'
ok "SSID with a quote refused" '! check x "$(printf "WIFI_SSID=a\"b")"'
ok "SSID with a pipe refused" '! check x "$(printf "WIFI_SSID=a|b")"'
ok "Wi-Fi password without SSID refused" '! check x "WIFI_PSK=password123"'
ok "Wi-Fi on with SSID and password accepted (no adapter needed)" 'check x "$(printf "WIFI=on\nWIFI_SSID=Office\nWIFI_PSK=password123")"'
ok "Wi-Fi on without a key refused" '! check x "$(printf "WIFI=on\nWIFI_SSID=Office")"'
ok "threshold out of range refused" '! check x "SESSION_THRESHOLD=200"'
ok "bad days refused" '! check x "POWER_ON_DAYS=1289"'
ok "bad time refused" '! check x "POWER_ON_TIME=25:00"'
ok "bad USB id refused" '! check x "USB_REDIRECT=1eaf:00x9"'
ok "unknown language refused" '! check x "LANGUAGE=xx"'
ok "RDP_EXTRA with shell characters refused" '! check x "RDP_EXTRA=/foo;reboot"'
# the messages follow the language the device is using now
printf 'LANGUAGE=it\n' > /etc/openthinrdp/openthinrdp.conf; printf 'HOSTNAME=12345\n' > "$T"
ok "messages in Italian" '$OTR/save-config.sh "$T" --print 2>&1 | grep -q "Nome macchina non valido"'
: > /etc/openthinrdp/openthinrdp.conf

# --- normalization: the stored form
printf 'USB_MODE=Dischi\nUSB_REDIRECT=1EAF:0009,346d:5678\nNTP=a.example.com;b.example.com\nSECURITY_UPDATES=Yes\nPOWER_ON_DAYS=5,1,3\nSHUTDOWN_SECS=030\n' > "$T"
P=$($OTR/save-config.sh "$T" --print 2>&1)
ok "aliases and separators normalized" 'echo "$P" | grep -qx "USB_MODE=disks" && echo "$P" | grep -qx "USB_REDIRECT=1eaf:0009 346d:5678" && echo "$P" | grep -qx "NTP=a.example.com b.example.com" && echo "$P" | grep -qx "SECURITY_UPDATES=on" && echo "$P" | grep -qx "POWER_ON_DAYS=135" && echo "$P" | grep -qx "SHUTDOWN_SECS=30"'
printf 'NETMODE=Statico\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53\n' > "$T"
ok "static alias normalized" '$OTR/save-config.sh "$T" --print 2>&1 | grep -qx "NETMODE=static"'
printf 'IPADDR=garbage\n' > "$T"
ok "invalid address cleared in DHCP mode" '$OTR/save-config.sh "$T" --print 2>&1 | grep -qx "IPADDR="'
tr_of(){ printf 'TRANSPORT=%s\n' "$1" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | sed -n 's/^TRANSPORT=//p'; }
ok "transport modes kept, anything else is auto" '[ "$(tr_of UDP)" = udp ] && [ "$(tr_of tcp)" = tcp ] && [ "$(tr_of auto)" = auto ] && [ "$(tr_of garbage)" = auto ]'

# --- real save: only given keys end in the device file
: > /etc/openthinrdp/openthinrdp.conf
printf 'BROKER=rdbroker.example.com\nDEFAULT_USER=alice\n' > "$T"
ok "save works" '$OTR/save-config.sh "$T" >/dev/null 2>&1'
ok "device file has the given keys" 'grep -qx "BROKER=rdbroker.example.com" $OTR_CONF && grep -qx "DEFAULT_USER=alice" $OTR_CONF'
ok "device file has no other keys" '[ "$(grep -c "^[A-Z]" $OTR_CONF)" = 2 ]'

# --- central configuration: a file written on Windows (BOM, CRLF, spaces, case, commas)
printf '\xEF\xBB\xBF; common settings\r\nUSB_MODE = Dischi\r\nUSB_REDIRECT=1EAF:0009, 346D:5678\r\nHOSTNAME=not-allowed-here\r\nNTP=a.example.com,b.example.com\r\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
ok "central applied" 'grep -q "^applied" $OTR_LIB/central-status'
ok "values stored normalized" 'grep -qx "USB_MODE=disks" $OTR_CONF && grep -qx "USB_REDIRECT=1eaf:0009 346d:5678" $OTR_CONF'
ok "HOSTNAME ignored in common.conf" '! grep -q "^HOSTNAME" $OTR_CONF && [ "$(hostname)" != not-allowed-here ]'
$OTR/central-apply.sh
ok "second run: in line, no loop" 'grep -q "^in line" $OTR_LIB/central-status'
N=$(grep -c "central configuration applied" $OTR_EVENTS)
$OTR/central-apply.sh; $OTR/central-apply.sh
ok "no event on repeated runs" '[ "$(grep -c "central configuration applied" $OTR_EVENTS)" = "$N" ]'
printf 'SHUTDOWN_SECS=99999\r\n' > $OTR_LIB/central-host.conf
$OTR/central-apply.sh; $OTR/central-apply.sh
ok "invalid central refused once" 'grep -q "^REJECTED" $OTR_LIB/central-status && [ "$(grep -c "REJECTED" $OTR_EVENTS)" = 1 ]'
ok "previous configuration kept" 'grep -qx "USB_MODE=disks" $OTR_CONF'
printf 'HOSTNAME=kiosk-test\r\n' > $OTR_LIB/central-host.conf
$OTR/central-apply.sh
ok "host file may set HOSTNAME" 'grep -q "^applied" $OTR_LIB/central-status'

# --- central values win over local changes; keys removed centrally go back to the defaults
: > $OTR_LIB/central-host.conf
printf 'USB_MODE=disks\nNTP=a.example.com\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
sed -i 's/^USB_MODE=.*/USB_MODE=all/' $OTR_CONF            # someone changes it in the settings dialog
$OTR/central-apply.sh
ok "a local change of a central key is overwritten" 'grep -qx "USB_MODE=disks" $OTR_CONF'
printf 'NTP=a.example.com\n' > $OTR_LIB/central-common.conf # USB_MODE removed from common.conf
$OTR/central-apply.sh
ok "a key removed centrally leaves the device settings" '! grep -q "^USB_MODE=" $OTR_CONF && [ "$(cfg USB_MODE)" = all ]'
ok "the release is logged" 'grep -q "back to the defaults: USB_MODE" $OTR_EVENTS'
ok "the other central key stays" 'grep -qx "NTP=a.example.com" $OTR_CONF'
printf 'WEB_BUTTON=app\nWEB_URL=https://intranet.example.com/\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
printf 'WEB_BUTTON=app\n' > $OTR_LIB/central-common.conf   # URL removed, button kept: not valid
$OTR/central-apply.sh
ok "an invalid release is refused and the key kept" 'grep -q "^WEB_URL=https://intranet.example.com/" $OTR_CONF && grep -q "NOT released" $OTR_EVENTS'
ok "the refused key stays managed for the next run" 'grep -qx WEB_URL $OTR_LIB/central-managed'
: > $OTR_LIB/central-common.conf; $OTR/central-apply.sh
ok "everything released when the central files are empty" '! grep -qE "^(WEB_BUTTON|WEB_URL|NTP)=" $OTR_CONF'

# --- status file: no Wi-Fi key, PIN only as (set)
printf 'SETTINGS_PIN_SHA256=%s\n' "$(printf 1234 | sha256sum | cut -c1-64)" >> $OTR_CONF
$OTR/report.sh >/dev/null 2>&1
ok "status written" '[ -s /run/openthinrdp-status.txt ]'
ok "PIN hash not in the status" '! grep -q "$(printf 1234 | sha256sum | cut -c1-64)" /run/openthinrdp-status.txt && grep -qx "CFG_SETTINGS_PIN_SHA256=(set)" /run/openthinrdp-status.txt'
ok "no WIFI_PSK in the status" '! grep -q WIFI_PSK /run/openthinrdp-status.txt'

echo "passed $PASS, failed $FAIL"
[ $FAIL = 0 ]
