#!/bin/bash
# Installer inside every update package (run by auto-update.sh as root, from the unpacked package).
# Brings an installed thin client to the files of the package without interrupting a remote session:
# if a session is open, the new kiosk starts at the next sign-in or boot.
set -u
cd "$(dirname "$0")"
OTR=/opt/openthinrdp
log(){ echo "$(date '+%H:%M:%S') $*"; }
log "### $(hostname), remote sessions open: $(pgrep -c xfreerdp3)"

# 1) everything must be valid before anything is touched
for f in rootfs/opt/openthinrdp/*.sh rootfs/opt/openthinrdp/lib/*.sh rootfs/opt/openthinrdp/lang/*.sh; do
  bash -n "$f" || { log "ERROR: syntax of $f"; exit 1; }
done
visudo -cqf rootfs/etc/sudoers.d/openthinrdp || { log "ERROR: sudoers file not valid"; exit 1; }

# 2) Debian packages the new version needs and that are missing (needs the Debian mirror)
if [ -f packages.list ]; then
  MISSING=$(grep -vE '^\s*(#|$)' packages.list | while read -r p; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done | tr '\n' ' ')
  if [ -n "${MISSING// /}" ]; then
    log "installing missing packages: $MISSING"
    apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q $MISSING >/dev/null 2>&1 || log "WARNING: some packages could not be installed: $MISSING"
  fi
fi

# 3) .deb files shipped in the package (e.g. a FreeRDP build): only when newer than the installed ones.
# /etc/openthinrdp/freerdp-pinned (with the reason inside) keeps FreeRDP as it is on this device.
if ls debs/*.deb >/dev/null 2>&1; then
  INST=()
  for d in debs/*.deb; do
    n=$(dpkg-deb -f "$d" Package); v=$(dpkg-deb -f "$d" Version); cur=$(dpkg-query -W -f '${Version}' "$n" 2>/dev/null)
    if [[ $n == *freerdp* || $n == *winpr* ]] && [ -f /etc/openthinrdp/freerdp-pinned ]; then
      log "$n not updated: pinned ($(head -1 /etc/openthinrdp/freerdp-pinned))"; continue
    fi
    { [ -z "$cur" ] || dpkg --compare-versions "$v" gt "$cur"; } && INST+=("./$d")
  done
  if [ ${#INST[@]} -gt 0 ]; then
    apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1
    if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q "${INST[@]}" >/dev/null 2>&1; then log "installed: ${INST[*]}"
    else log "ERROR: installing ${INST[*]}"; exit 1; fi
  fi
fi

# 4) files: the whole rootfs of the package. The device settings (/etc/openthinrdp/openthinrdp.conf,
# smb.cred, keys) are not in the rootfs, so they are never overwritten.
cp -a --no-preserve=ownership rootfs/. /
chmod 755 $OTR/*.sh; chmod 0440 /etc/sudoers.d/openthinrdp
# /etc/skel only reaches new accounts: the kiosk account gets its Openbox settings here
install -D -m644 -o kiosk -g kiosk rootfs/etc/skel/.config/openbox/rc.xml /home/kiosk/.config/openbox/rc.xml
[ -f VERSION ] && cp VERSION $OTR/VERSION
# site files, when the package carries them (make-update.sh -s)
if [ -d site ]; then
  [ -f site/site.conf ] && install -m644 site/site.conf /etc/openthinrdp/site.conf
  for f in logo splash; do [ -f site/$f.png ] && install -m644 site/$f.png $OTR/branding/$f.png; done
  # the boot splash follows by itself (branding.sh splash, at the next report): it rebuilds the initramfs
  ls site/ca/*.crt >/dev/null 2>&1 && { mkdir -p /etc/openthinrdp/ca; install -m644 site/ca/*.crt /etc/openthinrdp/ca/; }
  [ -f site/update-key.asc ] && install -m644 site/update-key.asc /etc/openthinrdp/update-key.asc
  [ -f site/authorized_keys ] && install -m644 site/authorized_keys /etc/openthinrdp/authorized_keys
fi

# 5) services, rules and settings applied again
systemctl daemon-reload
systemctl enable openthinrdp-boot.service openthinrdp-wol.service openthinrdp-report.timer openthinrdp-report.path openthinrdp-schedule.timer >/dev/null 2>&1
systemctl start openthinrdp-report.timer openthinrdp-report.path openthinrdp-schedule.timer >/dev/null 2>&1
udevadm control --reload; udevadm trigger --subsystem-match=input --action=change
$OTR/security-updates.sh >/dev/null
$OTR/browser-policy.sh
$OTR/apply.sh now
pgrep -x openbox >/dev/null && runuser -u kiosk -- env DISPLAY=:0 openbox --reconfigure >/dev/null 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') software update $(cat VERSION 2>/dev/null) installed" >> /var/log/openthinrdp/events.log

# 6) the new kiosk: at once if nobody is connected (restart of the X session, synchronous: started in the
# background inside the update unit it would be killed when the unit ends), otherwise at the next start
if pgrep -x xfreerdp3 >/dev/null; then log "remote session open: new kiosk at the next start"
else log "restarting the X session with the new kiosk"; sleep 1; pkill -x Xorg; fi
exit 0
