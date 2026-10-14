#!/bin/bash
# The USB devices that go to Windows whole wait until the remote desktop is up (kiosk.sh, as root through sudo).
#   hold VID:PID...   every connected USB device with one of these ids is disconnected (authorized=0) until
#                     "release", or by itself after 2 minutes whatever happens to the kiosk
#   release           every held device back: for Windows it is plugged in now, with the desktop running
# Why: Windows starts the redirected devices and the display of the session together. A device that hangs while
# Windows starts it holds Plug and Play for 60 s, the display driver of the session cannot report ready, and
# Windows closes the session (reason 15, "driver not ready"; FreeRDP #13719). Arriving after the desktop, a
# device that hangs fails on its own, as on a physical PC.
. /opt/openthinrdp/lib/common.sh
H=/run/openthinrdp-usb-held
release(){ local n
  for n in $(sort -u "$H" 2>/dev/null); do
    [[ $n =~ ^[0-9]+-[0-9.]+$ ]] && [ -f "/sys/bus/usb/devices/$n/authorized" ] && echo 1 > "/sys/bus/usb/devices/$n/authorized"
  done
  rm -f "$H"; }
case "$1" in
  hold)
    shift
    for id in "$@"; do [[ $id =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || { echo "not a VID:PID: $id" >&2; exit 2; }; done
    release   # anything still held from a previous connection
    systemctl stop openthinrdp-usb-release.timer >/dev/null 2>&1
    for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
      n=${d##*/}; [[ $n =~ ^[0-9]+-[0-9.]+$ ]] && [ -f "$d/idVendor" ] || continue
      [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue          # never a hub
      [ "$(cat "$d/authorized" 2>/dev/null)" = 1 ] || continue
      [[ " $* " == *" $(cat "$d/idVendor"):$(cat "$d/idProduct") "* ]] || continue
      echo 0 > "$d/authorized" && echo "$n" >> "$H"
    done
    [ -s "$H" ] && systemd-run --on-active=120 --unit=openthinrdp-usb-release --collect "$0" release >/dev/null 2>&1
    exit 0 ;;
  release)
    release; systemctl stop openthinrdp-usb-release.timer >/dev/null 2>&1; exit 0 ;;
  *) echo "usage: $0 hold VID:PID... | release" >&2; exit 2 ;;
esac
