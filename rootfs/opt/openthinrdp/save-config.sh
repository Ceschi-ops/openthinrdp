#!/bin/bash
# Validate and save the device settings, then apply them. Runs as root: from the settings dialog (sudo, kiosk
# user), from central-apply.sh and from the first boot setup.
# $1 = file with KEY=value lines. Keys not in the file keep their current value. Nothing touches the system
# before everything is valid; on error the messages go to stdout (one per line) and the exit code is 1.
# $2 = --print: validate and print every setting in its stored (normalized) form, change nothing.
# central-apply.sh uses it to compare like with like.
. /opt/openthinrdp/lib/common.sh
. /opt/openthinrdp/lib/secrets.sh
otr_lang
F="$1"; [ -f "$F" ] || { echo "$V_NODATA"; exit 1; }
has(){ grep -q "^$1=" "$F"; }
# value from the input file if present, else the current setting
get(){ if has "$1"; then sed -n "s/^$1=//p" "$F" | head -1 | tr -d '\r' | sed 's/^ *//; s/ *$//'; else cfg "$1"; fi; }
low(){ echo "$1" | tr 'A-Z' 'a-z'; }
onoff(){ case "$(low "$1")" in on|yes|true|1|si|sì|attivo|acceso) echo on ;; *) echo off ;; esac; }

ipok(){
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}
ip2int(){ local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d )); }
maskok(){ ipok "$1" || return 1; local m inv; m=$(ip2int "$1"); inv=$(( ~m & 0xFFFFFFFF )); [ "$m" -ne 0 ] && [ $(( inv & (inv + 1) )) -eq 0 ]; }
hostok(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] && ! [[ $1 =~ ^[0-9]+$ ]]; }
nameok(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$ ]]; }
userok(){ [[ $1 =~ ^[A-Za-z0-9._@\\-]{1,104}$ ]]; }
URLRE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?$'
urlok(){ [[ $1 =~ $URLRE ]]; }
BADTEXT='[<>&|"`$\\]'
textok(){ ! [[ $1 =~ $BADTEXT ]] && [ ${#1} -le 200 ]; }
SHARERE='^(\\\\|//)[A-Za-z0-9.-]+[\\/][A-Za-z0-9 ._$\\/-]+$'
EXTRARE='^[A-Za-z0-9 /:+,._=#-]*$'
TIMERE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
E=""; err(){ E+="- $*\n"; }
declare -A V

# --- remote desktop
V[HOSTNAME]=$(get HOSTNAME); [ -z "${V[HOSTNAME]}" ] && V[HOSTNAME]=$(hostname)
hostok "${V[HOSTNAME]}" || err "$V_HOSTNAME"
V[DEFAULT_USER]=$(get DEFAULT_USER); [ -z "${V[DEFAULT_USER]}" ] || userok "${V[DEFAULT_USER]}" || err "$V_USER"
V[BROKER]=$(get BROKER); [ -z "${V[BROKER]}" ] || nameok "${V[BROKER]}" || err "$V_BROKER"
V[BROKER_FALLBACK]=$(get BROKER_FALLBACK | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[BROKER_FALLBACK]}; do ipok "$t" || nameok "$t" || err "$V_FALLBACK $t"; done
V[DOMAIN]=$(get DOMAIN); [ -z "${V[DOMAIN]}" ] || nameok "${V[DOMAIN]}" || err "$V_DOMAIN"
V[LOAD_BALANCE_INFO]=$(get LOAD_BALANCE_INFO); [[ ${V[LOAD_BALANCE_INFO]} =~ ^[A-Za-z0-9._:/#=-]*$ ]] || err "$V_COLLECTION"
case "$(low "$(get TRANSPORT)")" in udp) V[TRANSPORT]=udp ;; tcp) V[TRANSPORT]=tcp ;; *) V[TRANSPORT]=auto ;; esac
case "$(low "$(get RDP_AUTH)")" in ntlm) V[RDP_AUTH]=ntlm ;; *) V[RDP_AUTH]=negotiate ;; esac
case "$(low "$(get RDP_CERT)")" in ignore) V[RDP_CERT]=ignore ;; verify) V[RDP_CERT]=verify ;; *) V[RDP_CERT]=tofu ;; esac
V[RDP_GFX]=$(get RDP_GFX); [[ ${V[RDP_GFX]} =~ ^[A-Za-z0-9:,]*$ ]] || err "$V_GFX"
V[RDP_KEYBOARD]=$(get RDP_KEYBOARD); [[ ${V[RDP_KEYBOARD]} =~ ^(0x[0-9a-fA-F]{8})?$ ]] || err "$V_RDPKBD"
V[RDP_EXTRA]=$(get RDP_EXTRA); [[ ${V[RDP_EXTRA]} =~ $EXTRARE ]] || err "$V_EXTRA"
case "$(low "$(get MULTIMON)")" in off|no|0) V[MULTIMON]=off ;; *) V[MULTIMON]=auto ;; esac
V[SESSION_THRESHOLD]=$(get SESSION_THRESHOLD)
{ [[ ${V[SESSION_THRESHOLD]} =~ ^[0-9]{1,3}$ ]] && [ $((10#${V[SESSION_THRESHOLD]})) -ge 5 ] && [ $((10#${V[SESSION_THRESHOLD]})) -le 120 ]; } || err "$V_THRESHOLD"
V[SHUTDOWN_SECS]=$(get SHUTDOWN_SECS)
{ [[ ${V[SHUTDOWN_SECS]} =~ ^[0-9]{1,4}$ ]] && [ $((10#${V[SHUTDOWN_SECS]})) -le 3600 ]; } || err "$V_SHUTDOWN"

# --- USB
case "$(low "$(get USB_MODE)")" in disks|dischi) V[USB_MODE]=disks ;; *) V[USB_MODE]=all ;; esac
V[USB_REDIRECT]=$(get USB_REDIRECT | tr -s ' ,;' ' ' | tr 'A-F' 'a-f' | sed 's/^ //; s/ $//')
[[ ${V[USB_REDIRECT]} =~ ^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$ ]] || err "$V_USBLIST"

# --- network
case "$(low "$(get NETMODE)")" in static|statico) V[NETMODE]=static ;; *) V[NETMODE]=dhcp ;; esac
V[IPADDR]=$(get IPADDR); V[NETMASK]=$(get NETMASK); V[GATEWAY]=$(get GATEWAY)
V[DNS1]=$(get DNS1); V[DNS2]=$(get DNS2)
if [ "${V[NETMODE]}" = static ]; then
  ipok "${V[IPADDR]}" || err "$V_IP"
  maskok "${V[NETMASK]}" || err "$V_NETMASK"
  ipok "${V[GATEWAY]}" || err "$V_GATEWAY"
  if ipok "${V[IPADDR]}" && maskok "${V[NETMASK]}" && ipok "${V[GATEWAY]}"; then
    m=$(ip2int "${V[NETMASK]}")
    [ $(( $(ip2int "${V[IPADDR]}") & m )) -eq $(( $(ip2int "${V[GATEWAY]}") & m )) ] || err "$V_SUBNET"
  fi
  ipok "${V[DNS1]}" || err "$V_DNS_STATIC"
else
  # with DHCP the address fields stay as a reminder but are not used
  ipok "${V[IPADDR]}" || V[IPADDR]=""; maskok "${V[NETMASK]}" || V[NETMASK]=""; ipok "${V[GATEWAY]}" || V[GATEWAY]=""
  [ -z "${V[DNS1]}" ] || ipok "${V[DNS1]}" || err "$V_DNS1"
fi
[ -z "${V[DNS2]}" ] || ipok "${V[DNS2]}" || err "$V_DNS2"
V[NTP]=$(get NTP | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[NTP]}; do ipok "$t" || nameok "$t" || err "$V_NTP $t"; done

# --- Wi-Fi: the key lives ONLY in the TPM or in a root-only file (lib/secrets.sh); an empty password keeps the saved one
WCF=$(secret_path wifi.conf)
V[WIFI]=$(onoff "$(get WIFI)"); V[WIFI_SSID]=$(get WIFI_SSID)
V[WIFI_COUNTRY]=$(get WIFI_COUNTRY | tr 'a-z' 'A-Z'); [[ ${V[WIFI_COUNTRY]} =~ ^([A-Z]{2})?$ ]] || err "$V_COUNTRY"
WPIN=$(sed -n 's/^WIFI_PSK=//p' "$F" | head -1 | tr -d '\r'); WHEX=""
if [ -n "$WPIN" ]; then
  if [[ $WPIN =~ ^[0-9a-fA-F]{64}$ ]]; then WHEX=$(low "$WPIN")
  elif [ ${#WPIN} -ge 8 ] && [ ${#WPIN} -le 63 ]; then WHEX=$(wpa_passphrase "${V[WIFI_SSID]}" "$WPIN" 2>/dev/null | sed -n 's/^[[:space:]]*psk=//p')
  else err "$V_WIFIPSK"; fi
  [ -n "${V[WIFI_SSID]}" ] || err "$V_WIFINOSSID"
fi
BADSSID='["|\\]'
[ -z "${V[WIFI_SSID]}" ] || { [ ${#V[WIFI_SSID]} -le 32 ] && ! [[ ${V[WIFI_SSID]} =~ $BADSSID ]]; } || err "$V_SSID"
# the key already saved, valid only for the same network (a country change rewrites the file with it)
OLDHEX=""; grep -qF "ssid=\"${V[WIFI_SSID]}\"" $WCF 2>/dev/null && OLDHEX=$(sed -n 's/^[[:space:]]*psk=//p' $WCF | head -1)
# Wi-Fi on without an adapter is not an error: a common configuration may enable Wi-Fi for every device,
# and apply.sh simply does nothing on the wired-only ones
if [ "${V[WIFI]}" = on ]; then
  [ -n "${V[WIFI_SSID]}" ] || err "$V_SSID"
  command -v wpa_supplicant >/dev/null || err "$V_NOWPA"
  [ -n "$WHEX" ] || [ -n "$OLDHEX" ] || err "$V_WIFIMISSING ${V[WIFI_SSID]}"
fi

# --- management
V[MGMT_SHARE]=$(get MGMT_SHARE)
[ -z "${V[MGMT_SHARE]}" ] || [[ ${V[MGMT_SHARE]} =~ $SHARERE ]] || err "$V_SHARE"
# account of the management folder: the user in the settings, the password ONLY in the TPM or a root-only file, like the
# Wi-Fi key; an empty password keeps the saved one. DOMAIN\user, user@domain, or user (then the domain is DOMAIN).
# Without MGMT_USER the file is left as it is (e.g. the smb.cred built into the image).
CRED=$(secret_path smb.cred)
V[MGMT_USER]=$(get MGMT_USER); [ -z "${V[MGMT_USER]}" ] || userok "${V[MGMT_USER]}" || err "$V_MGMT_USER"
MPW=$(sed -n 's/^MGMT_PASSWORD=//p' "$F" | head -1 | tr -d '\r')
OLDPW=$(sed -n 's/^password=//p' "$CRED" 2>/dev/null | head -1)
[ ${#MPW} -le 256 ] || err "$V_MGMT_PASSWORD"
[ -n "$MPW" ] && [ -z "${V[MGMT_USER]}" ] && err "$V_MGMT_NOUSER"
[ -n "${V[MGMT_USER]}" ] && [ -z "$MPW" ] && [ -z "$OLDPW" ] && err "$V_MGMT_NOPASSWORD"
V[SECURITY_UPDATES]=$(onoff "$(get SECURITY_UPDATES)")
V[TPM_SECRETS]=$(onoff "$(get TPM_SECRETS)")
case "$(low "$(get UPDATE_FROM)")" in share|cartella|folder) V[UPDATE_FROM]=share ;; off|no|none|nessuno) V[UPDATE_FROM]=off ;; *) V[UPDATE_FROM]=github ;; esac
[ "${V[UPDATE_FROM]}" = share ] && [ -z "${V[MGMT_SHARE]}" ] && err "$V_UPDATE_SHARE"
V[UPDATE_GITHUB]=$(get UPDATE_GITHUB); [[ ${V[UPDATE_GITHUB]} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || err "$V_UPDATE_GITHUB"
V[SSH]=$(onoff "$(get SSH)")

# --- web button and kiosk page
case "$(low "$(get WEB_BUTTON)")" in app|portale|portal) V[WEB_BUTTON]=app ;; browser|chrome|chromium) V[WEB_BUTTON]=browser ;; kiosk) V[WEB_BUTTON]=kiosk ;; *) V[WEB_BUTTON]=none ;; esac
V[WEB_LABEL]=$(get WEB_LABEL); textok "${V[WEB_LABEL]}" || err "$V_WEBLABEL"
V[WEB_URL]=$(get WEB_URL); [ -z "${V[WEB_URL]}" ] || urlok "${V[WEB_URL]}" || err "$V_WEBURL"
case "${V[WEB_BUTTON]}" in app|browser) [ -n "${V[WEB_URL]}" ] || err "$V_WEBURL_NEEDED" ;; esac
V[WEB_ALLOW]=$(get WEB_ALLOW | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[WEB_ALLOW]}; do urlok "$t" || err "$V_WEBALLOW $t"; done
V[KIOSK_URL]=$(get KIOSK_URL); [ -z "${V[KIOSK_URL]}" ] || urlok "${V[KIOSK_URL]}" || err "$V_KIOSKURL"
[ "${V[WEB_BUTTON]}" = kiosk ] && [ -z "${V[KIOSK_URL]}" ] && err "$V_KIOSKURL_NEEDED"
V[KIOSK_RELOAD_MIN]=$(get KIOSK_RELOAD_MIN)
{ [[ ${V[KIOSK_RELOAD_MIN]} =~ ^[0-9]{1,4}$ ]] && [ $((10#${V[KIOSK_RELOAD_MIN]})) -le 1440 ]; } || err "$V_RELOAD"

# --- power schedule
V[POWER_ON_TIME]=$(get POWER_ON_TIME); [ -z "${V[POWER_ON_TIME]}" ] || [[ ${V[POWER_ON_TIME]} =~ $TIMERE ]] || err "$V_POWERON"
V[POWER_OFF_TIME]=$(get POWER_OFF_TIME); [ -z "${V[POWER_OFF_TIME]}" ] || [[ ${V[POWER_OFF_TIME]} =~ $TIMERE ]] || err "$V_POWEROFF"
d=$(get POWER_ON_DAYS); [ -z "$(echo "$d" | tr -d '1-7 ,;')" ] || err "$V_DAYS"
V[POWER_ON_DAYS]=$(echo "$d" | tr -cd '1-7' | fold -w1 | sort -u | tr -d '\n'); [ -z "${V[POWER_ON_DAYS]}" ] && V[POWER_ON_DAYS]=1234567

# --- look and language
V[LANGUAGE]=$(low "$(get LANGUAGE)"); { [[ ${V[LANGUAGE]} =~ ^[a-z]{2}$ ]] && [ -f "$OTR/lang/${V[LANGUAGE]}.sh" ]; } || err "$V_LANGUAGE"
V[KEYBOARD]=$(get KEYBOARD); [[ ${V[KEYBOARD]} =~ ^[a-z][a-z0-9_-]{1,15}$ ]] || err "$V_KEYBOARD"
V[TITLE]=$(get TITLE); textok "${V[TITLE]}" || err "$V_TITLE"
V[SUPPORT_TEXT]=$(get SUPPORT_TEXT); textok "${V[SUPPORT_TEXT]}" || err "$V_SUPPORT"
V[LOGO]=$(get LOGO); [[ ${V[LOGO]} =~ ^(/[A-Za-z0-9._/-]+\.png)?$ ]] || err "$V_LOGO"
for k in BG_TOP BG_BOTTOM; do V[$k]=$(get $k); [[ ${V[$k]} =~ ^#[0-9a-fA-F]{6}$ ]] || err "$V_COLOR $k"; done
V[SETTINGS_PIN_SHA256]=$(low "$(get SETTINGS_PIN_SHA256)"); [[ ${V[SETTINGS_PIN_SHA256]} =~ ^([0-9a-f]{64}|pbkdf2-sha256:[0-9]{4,7}:[0-9a-f]{32}:[0-9a-f]{64})?$ ]] || err "$V_PIN"

if [ -n "$E" ]; then printf '%b' "$E"; exit 1; fi
for k in SESSION_THRESHOLD SHUTDOWN_SECS KIOSK_RELOAD_MIN; do V[$k]=$((10#${V[$k]})); done
if [ "${2:-}" = --print ]; then
  for k in $(cfg_keys); do echo "$k=${V[$k]}"; done
  # secrets as a hash: central-apply.sh compares them, nobody can read them back (the kiosk user may run this)
  hs(){ [ -n "$1" ] && printf '%s' "$1" | sha256sum | cut -c1-64; }
  echo "WIFI_PSK=$(hs "${WHEX:-$OLDHEX}")"
  echo "MGMT_PASSWORD=$(hs "${MPW:-$OLDPW}")"
  exit 0
fi

# --- save: the device file keeps the keys it already had plus the ones given now; the others keep
# following site.conf and the project defaults
mkdir -p "$OTR_ETC"
declare -A OUT
[ -f "$OTR_CONF" ] && while IFS='=' read -r k v; do [ -n "$k" ] && OUT[$k]=$v; done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$OTR_CONF")
for k in $(cfg_keys); do [ "$k" = HOSTNAME ] && continue; { has "$k" || [ -n "${OUT[$k]+x}" ]; } && OUT[$k]=${V[$k]}; done
T=$(mktemp "$OTR_ETC/.conf.XXXXXX")
{ echo "# Settings of this device, written by save-config.sh. See /opt/openthinrdp/defaults.conf."
  for k in $(cfg_keys); do [ -n "${OUT[$k]+x}" ] && echo "$k=${OUT[$k]}"; done; } > "$T"
chmod 644 "$T"; mv -f "$T" "$OTR_CONF"

# Wi-Fi: the file is written with the new key, or with the saved one of the same network (country changed)
[ -z "$WHEX" ] && WHEX=$OLDHEX
if [ -n "$WHEX" ] && [ -n "${V[WIFI_SSID]}" ]; then
  mkdir -p /etc/wpa_supplicant
  NW=$(mktemp); chmod 600 "$NW"
  { echo "ctrl_interface=/run/wpa_supplicant"; [ -n "${V[WIFI_COUNTRY]}" ] && echo "country=${V[WIFI_COUNTRY]}"
    printf 'network={\n\tssid="%s"\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}\n' "${V[WIFI_SSID]}" "$WHEX"; } > "$NW"
  if ! cmp -s "$NW" $WCF; then
    secret_store wifi.conf "$NW"
    WL=$(ls /sys/class/net | grep -E '^wl' | head -1)
    [ -n "$WL" ] && wpa_cli -p /run/wpa_supplicant -i "$WL" reconfigure >/dev/null 2>&1
  else rm -f "$NW"; fi
fi
# account of the management folder (only with MGMT_USER: otherwise the file of the image stays)
if [ -n "${V[MGMT_USER]}" ]; then
  MU=${V[MGMT_USER]}; MD=${V[DOMAIN]}
  case "$MU" in *\\*) MD=${MU%%\\*}; MU=${MU#*\\} ;; *@*) MD=${MU#*@}; MU=${MU%%@*} ;; esac
  NC=$(mktemp "$OTR_ETC/.cred.XXXXXX"); chmod 600 "$NC"
  { echo "username=$MU"; echo "password=${MPW:-$OLDPW}"; [ -n "$MD" ] && echo "domain=$MD"; } > "$NC"
  if cmp -s "$NC" "$CRED"; then rm -f "$NC"; else secret_store smb.cred "$NC"; fi
fi
# hostname, and /etc/hosts always matching it (otherwise sudo and X look the name up on the network)
H=${V[HOSTNAME]}
[ "$(hostname)" != "$H" ] && { hostnamectl set-hostname "$H" 2>/dev/null || hostname "$H"; }
DOM=$(low "${V[DOMAIN]}")
if [[ $DOM == *.* ]]; then L=$(printf '127.0.1.1\t%s.%s\t%s' "$H" "$DOM" "$H"); else L=$(printf '127.0.1.1\t%s' "$H"); fi
if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/$L/" /etc/hosts; else echo "$L" >> /etc/hosts; fi
"$OTR/browser-policy.sh"
"$OTR/schedule.sh" alarm         # power-on alarm reprogrammed at once with the new times
"$OTR/apply.sh" now
exit 0
