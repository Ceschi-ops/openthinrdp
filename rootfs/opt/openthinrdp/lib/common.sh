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

# logo and boot image in use: the ones of the management folder (branding.sh) when there, otherwise LOGO and
# the image's own
otr_logo(){ if [ -f "$OTR_LIB/branding/logo.png" ]; then echo "$OTR_LIB/branding/logo.png"; else cfg LOGO; fi; }
otr_splash(){ if [ -f "$OTR_LIB/branding/splash.png" ]; then echo "$OTR_LIB/branding/splash.png"; else echo "$OTR/branding/splash.png"; fi; }

# event log: one line per event, English, sent to the management folder by report.sh
ev(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$OTR_EVENTS" 2>/dev/null; }

# interface language: English first, so a string missing from a translation stays readable
otr_lang(){
  . "$OTR/lang/en.sh"
  local l; l=$(cfg LANGUAGE)
  [[ $l =~ ^[a-z]{2}$ ]] && [ "$l" != en ] && [ -f "$OTR/lang/$l.sh" ] && . "$OTR/lang/$l.sh"
  return 0
}
