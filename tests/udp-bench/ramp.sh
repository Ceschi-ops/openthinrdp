#!/bin/bash
# Loss on every packet from the session host, step by step, on the running bench session (session.sh).
# Usage: ramp.sh <seconds per step> <percent> [<percent>...]   ->  ramp.log; stops when the session ends.
set -e
DIR=$(cd "$(dirname "$0")" && pwd); NAME=${NAME:-bench}; LOG=$DIR/ramp.log
P=$(cat "/tmp/bench-$NAME.pid"); DUR=$1; shift
echo "start $(date +%T), session $NAME pid $P" > "$LOG"
for pct in "$@"; do
  "$DIR/line.sh" loss "$pct" | sed "s/^/$(date +%T) $pct%: /" >> "$LOG"
  for s in $(seq 1 "$DUR"); do kill -0 "$P" 2>/dev/null || { echo "$(date +%T) SESSION ENDED at $pct%" >> "$LOG"; break 2; }; sleep 1; done
  kill -0 "$P" 2>/dev/null && echo "$(date +%T) $pct%: session still up after $DUR s" >> "$LOG"
done
grep -aE 'rdpudp_fail|broke down|BIO_read|ERRCONNECT' "/tmp/bench-$NAME.log" | tail -3 >> "$LOG" || true
"$DIR/line.sh" off >> "$LOG"; echo "end $(date +%T)" >> "$LOG"
