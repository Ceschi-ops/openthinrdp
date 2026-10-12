#!/bin/bash
# The bench session: FreeRDP on an invisible screen (Xvfb :99), logging the UDP transport at debug level.
#   session.sh start <name> [<xfreerdp binary>]   (default xfreerdp3 of the system)
#   session.sh status <name>
#   session.sh stop <name>
# Connection from the environment: RDP_HOST, RDP_USER, RDP_PASSWORD, optional RDP_DOMAIN and RDP_EXTRA.
N=${2:-bench}; LOG=/tmp/bench-$N.log; PID=/tmp/bench-$N.pid
case "$1" in
start)
  : "${RDP_HOST:?}" "${RDP_USER:?}" "${RDP_PASSWORD:?}"
  XB=${3:-xfreerdp3}
  pgrep -f 'Xvfb :99' >/dev/null || { Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 & sleep 1; }
  read -ra extra <<< "${RDP_EXTRA:-}"
  # the timeout the kiosk uses (20 s instead of FreeRDP's 9 s), so the numbers are those of a real device
  DISPLAY=:99 WLOG_LEVEL=INFO WLOG_FILTER='com.freerdp.core.multitransport:DEBUG' \
    nohup "$XB" /v:"$RDP_HOST" /u:"$RDP_USER" ${RDP_DOMAIN:+/d:"$RDP_DOMAIN"} /p:"$RDP_PASSWORD" /cert:ignore \
    /size:1280x800 /bpp:32 /gfx:progressive,AVC420:off,AVC444:off /network:auto /timeout:20000 "${extra[@]}" \
    > "$LOG" 2>&1 < /dev/null &
  echo $! > "$PID"; sleep 15; "$0" status "$N" ;;
status)
  P=$(cat "$PID" 2>/dev/null)
  if kill -0 "$P" 2>/dev/null; then echo "$N: up, UDP sockets: $(ss -uanpH | grep -c "pid=$P,")"; else echo "$N: ended"; fi
  grep -aE 'tunnel ready|rdpudp_fail|broke down|BIO_read|ERRCONNECT' "$LOG" | tail -4 ;;
stop)
  kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null; echo "stopped $N" ;;
*) echo "session.sh start|status|stop <name>"; exit 1 ;;
esac
