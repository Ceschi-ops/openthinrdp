#!/bin/bash
# Started by an update installed while a remote session was open (install.sh): the running kiosk is still the old
# one. As soon as that session is over and the device is back to the sign-in screen, or a new connection starts,
# the X session is restarted with the new kiosk, so the next connection already has the new version. A device
# that switches off at the end of the session is left alone: it starts with the new kiosk anyway.
. /opt/openthinrdp/lib/common.sh
while pgrep -x xfreerdp3 >/dev/null; do sleep 2; done
for i in $(seq 1 7200); do
  [ -f /tmp/openthinrdp-poweroff-pending ] && exit 0
  if pgrep -f -- '--class=OtrLogin' >/dev/null || pgrep -x xfreerdp3 >/dev/null; then
    ev "software update: new kiosk loaded after the session"
    pkill -x Xorg
    exit 0
  fi
  sleep 1
done
