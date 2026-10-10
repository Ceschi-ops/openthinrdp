#!/bin/bash
# Wake-on-LAN (magic packet) on every wired adapter that supports it. Some drivers (e.g. r8169) leave it off
# and after power off the adapter no longer listens. The firmware must allow it too (Dell: "Wake on LAN"
# enabled and "Deep Sleep Control" disabled).
for i in /sys/class/net/e*; do
  [ -e "$i/device" ] || continue
  n=$(basename "$i")
  ethtool "$n" 2>/dev/null | grep -q 'Supports Wake-on:.*g' && ethtool -s "$n" wol g && echo "$n: wake-on-lan on"
done
exit 0
