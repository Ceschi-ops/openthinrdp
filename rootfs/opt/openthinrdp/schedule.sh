#!/bin/bash
# Scheduled power on and off: POWER_ON_TIME / POWER_OFF_TIME = hh:mm (empty = never), POWER_ON_DAYS = days of
# the power on, 1 = Monday ... 7 = Sunday. Runs as root every minute (openthinrdp-schedule.timer);
# save-config.sh runs it with "alarm" to reprogram only the power on at once.
# Power on: RTC wake alarm. Works only if the firmware lets it through (on Dell: "Deep Sleep Control"
#   disabled); with the device off no network is needed.
# Power off: within 5 minutes after the time, if the device was already on at that time (switched on by hand
#   later = stays on). With an open remote session it waits for the session to end. A 60 s warning with
#   "Cancel" comes first.
. /opt/openthinrdp/lib/common.sh
otr_lang
RTC=/sys/class/rtc/rtc0/wakealarm
STF=/run/openthinrdp-schedule-off      # "<day> due|postponed|cancelled|done"
TIMERE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
ON=$(cfg POWER_ON_TIME); OFFT=$(cfg POWER_OFF_TIME)
DAYS=$(cfg POWER_ON_DAYS | tr -cd '1-7'); [ -z "$DAYS" ] && DAYS=1234567
NOW=$(date +%s); TODAY=$(date +%F)

# --- 1) alarm: next POWER_ON_TIME on one of the chosen days, at least 3 minutes from now
AL=0
if [[ $ON =~ $TIMERE ]]; then
  for d in 0 1 2 3 4 5 6 7; do
    t=$(date -d "$(date -d "today + $d days" +%F) $ON" +%s 2>/dev/null) || continue
    [ "$t" -gt $((NOW + 180)) ] && [[ $DAYS == *$(date -d "@$t" +%u)* ]] && { AL=$t; break; }
  done
fi
if [ -w $RTC ]; then
  # the RTC normally keeps UTC on Linux; if it keeps local time the alarm moves by the UTC offset
  ALR=$AL
  if [ $AL -gt 0 ] && [ "$(timedatectl show -p LocalRTC --value 2>/dev/null)" = yes ]; then
    Z=$(date -d "@$AL" +%z); ALR=$(( AL + ${Z:0:1}1 * (10#${Z:1:2} * 3600 + 10#${Z:3:2} * 60) ))
  fi
  CUR=$(cat $RTC 2>/dev/null)
  if [ "${CUR:-0}" != "$ALR" ]; then
    echo 0 > $RTC 2>/dev/null
    if [ $AL -gt 0 ]; then
      echo $ALR > $RTC 2>/dev/null
      if [ "$(cat $RTC 2>/dev/null)" = "$ALR" ]; then ev "power on scheduled: $(date -d "@$AL" '+%a %d/%m %H:%M')"
      # alarm refused by the clock: reported once
      elif [ "$(cat /run/openthinrdp-schedule-err 2>/dev/null)" != "$AL" ]; then
        ev "ERROR: the RTC does not accept the alarm for $(date -d "@$AL" '+%d/%m %H:%M')"; echo $AL > /run/openthinrdp-schedule-err
      fi
    elif [ -n "$CUR" ]; then ev "scheduled power on removed"; fi
  fi
elif [ $AL -gt 0 ] && [ ! -f /run/openthinrdp-schedule-err ]; then
  ev "ERROR: scheduled power on impossible, this device has no RTC alarm (rtc0)"; touch /run/openthinrdp-schedule-err
fi
[ "$1" = alarm ] && exit 0

# --- 2) power off
[[ $OFFT =~ $TIMERE ]] || exit 0
T=$(date -d "today $OFFT" +%s)
BOOTED=$(( NOW - $(cut -d. -f1 /proc/uptime) ))
STATE=$(cat $STF 2>/dev/null)
# the time has just passed (5 minutes of margin if the timer is late) and the device was already on then
if [ "$NOW" -ge "$T" ] && [ "$NOW" -lt $((T + 300)) ] && [ "$BOOTED" -lt "$T" ] && [[ $STATE != "$TODAY "* ]]; then
  echo "$TODAY due" > $STF; STATE="$TODAY due"
fi
# power off pending (also from last night, if the session ended after midnight)
case "$STATE" in *" due"|*" postponed") ;; *) exit 0 ;; esac
in_session(){ local p; for p in $(pgrep -x xfreerdp3); do tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q '^/u:' && return 0; done; return 1; }
if in_session; then
  [[ $STATE == *" due" ]] && { ev "power off at $OFFT postponed: remote session open, switching off when it ends"; echo "${STATE%% *} postponed" > $STF; }
  exit 0
fi
# warning with Cancel (whoever is using the device keeps it on; without keyboard and mouse it switches off)
RC=70
if pgrep -x Xorg >/dev/null && id "$OTR_KIOSK_USER" >/dev/null 2>&1; then
  runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 yad --title="$(cfg TITLE)" --center --on-top --sticky --width=420 \
    --timeout=60 --timeout-indicator=bottom --text="<b>$(printf "$L_SCHED_TITLE" "$OFFT")</b>\n$L_SCHED_TEXT" \
    --button="$L_CANCEL:1" >/dev/null 2>&1
  RC=$?
fi
# 70 = expired; 1 = Cancel; anything else (X not reachable, dialog closed by the kiosk) = switch off anyway
if [ $RC -eq 1 ]; then ev "power off at $OFFT cancelled by the user"; echo "$TODAY cancelled" > $STF; exit 0; fi
# a session may have started during the warning
in_session && { ev "power off at $OFFT postponed: session opened during the warning"; echo "${STATE%% *} postponed" > $STF; exit 0; }
echo "$TODAY done" > $STF
ev "scheduled power off ($OFFT)"
wait_update; sleep 2; systemctl poweroff
exit 0
