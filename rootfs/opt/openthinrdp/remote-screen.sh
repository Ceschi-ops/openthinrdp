#!/bin/bash
# Remote screen (manager > Remote screen), run as root over SSH by an administrator (otradmin): the screen of the
# device in the administrator's browser, reachable only through the SSH tunnel. Nothing listens on the network.
#   start   x11vnc on the X display (127.0.0.1:5900, one-time password) and the noVNC viewer with its WebSocket
#           bridge (127.0.0.1:6080, vncbridge.py), in the unit otr-remote-screen; prints PORT=6080 and PASSWORD=...
#           Stops by itself after 2 hours. While it is on, the screen says so and the event log records it.
#   stop    off
#   status  on or off
#   run     what the unit runs
. /opt/openthinrdp/lib/common.sh
otr_lang
U=otr-remote-screen
ON=/run/openthinrdp-remote-screen          # exists while on: the notice on the screen stays while it is there
PF=/run/openthinrdp/vnc.pass
case "$1" in
  start)
    [ "$(cfg REMOTE_SCREEN)" = off ] && { echo "ERROR=the remote screen is off on this device (REMOTE_SCREEN=off)"; exit 3; }
    command -v x11vnc >/dev/null || { echo "ERROR=x11vnc is not installed (the next update installs it)"; exit 4; }
    pgrep -x Xorg >/dev/null || { echo "ERROR=no screen running"; exit 5; }
    systemctl stop $U.service >/dev/null 2>&1
    # VNC authentication uses 8 characters at most
    PW=$(tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom | head -c 8)
    install -d -m 700 /run/openthinrdp; rm -f "$PF"
    ( umask 077; x11vnc -storepasswd "$PW" "$PF" >/dev/null 2>&1 ) || { echo "ERROR=password"; exit 6; }
    systemd-run --unit=$U --collect -p RuntimeMaxSec=7200 "$0" run >/dev/null 2>&1
    for i in $(seq 1 40); do
      ss -ltnH 2>/dev/null | grep -q '127.0.0.1:6080 ' && ss -ltnH | grep -q '127.0.0.1:5900 ' && break; sleep 0.25
    done
    ss -ltnH | grep -q '127.0.0.1:6080 ' || { echo "ERROR=did not start (journalctl -u $U)"; systemctl stop $U.service >/dev/null 2>&1; exit 7; }
    echo "PORT=6080"; echo "PASSWORD=$PW" ;;
  stop) systemctl stop $U.service >/dev/null 2>&1; echo "STOPPED" ;;
  status) if systemctl is-active -q $U.service; then echo on; else echo off; fi ;;
  run)
    touch "$ON"
    ev "remote screen: started by an administrator over SSH (stops by itself after 2 hours)"
    stop_all(){ trap - TERM INT EXIT; rm -f "$ON" "$PF"; kill $(jobs -p) 2>/dev/null; ev "remote screen: stopped"; exit 0; }
    trap stop_all TERM INT EXIT
    runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 python3 "$OTR/ui.py" toast --text="$L_REMOTE_SCREEN_ON" --while-file="$ON" >/dev/null 2>&1 &
    # -forever: the viewer may reconnect; -shared: the user keeps the mouse and keyboard
    x11vnc -display :0 -auth guess -localhost -rfbport 5900 -rfbauth "$PF" -forever -shared -noxdamage -quiet >/dev/null 2>&1 &
    XV=$!
    python3 "$OTR/vncbridge.py" 6080 5900 "$OTR/novnc" >/dev/null 2>&1 &
    BR=$!
    # either of the two ending ends the remote screen (not the notice: X restarting closes it)
    wait -n $XV $BR
    stop_all ;;
  *) echo "usage: $0 start | stop | status"; exit 2 ;;
esac
