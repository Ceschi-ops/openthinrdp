# OpenThinRDP: paths, settings and event log shared by every script. Source it: . /opt/openthinrdp/lib/common.sh
OTR=/opt/openthinrdp
OTR_ETC=/etc/openthinrdp
OTR_CONF=$OTR_ETC/openthinrdp.conf
OTR_SITE=$OTR_ETC/site.conf
OTR_DEFAULTS=$OTR/defaults.conf
OTR_LIB=/var/lib/openthinrdp
OTR_LOG=/var/log/openthinrdp
OTR_EVENTS=$OTR_LOG/events.log
# the account that runs the X session and the kiosk (no password, no shell login over the network)
OTR_KIOSK_USER=kiosk

# cfg KEY: value of a setting. The first file that defines the key wins (device, then site, then defaults),
# so an empty value in the device file deliberately clears a site default.
cfg(){
  local f
  for f in "$OTR_CONF" "$OTR_SITE" "$OTR_DEFAULTS"; do
    [ -f "$f" ] && grep -q "^$1=" "$f" && { sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r'; return; }
  done
}
# cfg_num KEY DEFAULT: a number, or DEFAULT when the value is missing or not a number
cfg_num(){ local v; v=$(cfg "$1"); [[ $v =~ ^[0-9]{1,6}$ ]] && echo $((10#$v)) || echo "$2"; }
# every key that a configuration file may contain (the ones documented in defaults.conf + HOSTNAME)
cfg_keys(){ echo HOSTNAME; grep -oE '^[A-Z][A-Z0-9_]*=' "$OTR_DEFAULTS" | tr -d '='; }

# logo and background picture in use: the ones of the management folder (branding.sh) when there, otherwise LOGO and
# the image's own
otr_logo(){ if [ -f "$OTR_LIB/branding/logo.png" ]; then echo "$OTR_LIB/branding/logo.png"; else cfg LOGO; fi; }
otr_splash(){ if [ -f "$OTR_LIB/branding/splash.png" ]; then echo "$OTR_LIB/branding/splash.png"; else echo "$OTR/branding/splash.png"; fi; }

# event log: one line per event, English, sent to the management folder by report.sh
ev(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$OTR_EVENTS" 2>/dev/null; }

# The name to connect to with Kerberos. The ticket is for TERMSRV/<server name>, and a name shared by several servers
# (a round-robin alias for the brokers) or an IP address is nobody's: the Kerberos library then looks the address up
# by itself and may pick another broker than the one connected to, which cannot open the ticket (KRB_ERROR,
# SEC_E_INTERNAL_ERROR). So the device picks one of the addresses and uses that server's own name, when its address
# leads back to it; otherwise the name stays as it is.
krb_host(){
  local ip n
  ip=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | shuf -n 1)
  [ -n "$ip" ] || { echo "$1"; return; }
  n=$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
  if [[ $n == *.* ]] && getent ahostsv4 "$n" 2>/dev/null | awk '{print $1}' | grep -qx "$ip"; then echo "$n"; else echo "$1"; fi
}

# interface language: English first, so a string missing from a translation stays readable
otr_lang(){
  . "$OTR/lang/en.sh"
  local l; l=$(cfg LANGUAGE)
  [[ $l =~ ^[a-z]{2}$ ]] && [ "$l" != en ] && [ -f "$OTR/lang/$l.sh" ] && . "$OTR/lang/$l.sh"
  return 0
}

# never switch off in the middle of a software update (an interrupted install is only retried 10 minutes later):
# wait for it, 15 minutes at most
wait_update(){ local i; for i in $(seq 1 180); do systemctl is-active -q openthinrdp-update.service || return 0; sleep 5; done; }
