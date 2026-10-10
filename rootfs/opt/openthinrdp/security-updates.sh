#!/bin/bash
# Automatic updates: Debian SECURITY updates only, FreeRDP excluded (it is updated by hand, after testing).
# Never during boot (20-30 minutes later, then every 12 hours, lowest priority), never an automatic reboot.
# On/off: SECURITY_UPDATES in the settings, applied by apply.sh. Run once when the image is built.
cat > /etc/apt/apt.conf.d/52openthinrdp-security <<'EOF'
// OpenThinRDP: only SECURITY updates of Debian stable. "#clear" removes the default origins of
// 50unattended-upgrades (which also include the regular point release updates).
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
// FreeRDP is updated by hand after testing: a new version can change how sessions and devices behave
Unattended-Upgrade::Package-Blacklist {
        "freerdp";
        "libfreerdp";
        "libwinpr";
        "winpr";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::MinimalSteps "true";
EOF
# no "apt-mark hold" on FreeRDP: a manual "apt full-upgrade" must still be able to update it

# timing: nothing at boot (it must stay fast), then every 12 hours at idle priority
mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d \
         /etc/systemd/system/apt-daily.service.d /etc/systemd/system/apt-daily-upgrade.service.d
printf '[Timer]\nOnCalendar=\nOnBootSec=20min\nOnUnitActiveSec=12h\nRandomizedDelaySec=5min\nPersistent=false\n' \
  > /etc/systemd/system/apt-daily.timer.d/openthinrdp.conf
printf '[Timer]\nOnCalendar=\nOnBootSec=30min\nOnUnitActiveSec=12h\nRandomizedDelaySec=5min\nPersistent=false\n' \
  > /etc/systemd/system/apt-daily-upgrade.timer.d/openthinrdp.conf
for s in apt-daily apt-daily-upgrade; do
  printf '[Service]\nNice=19\nIOSchedulingClass=idle\nCPUSchedulingPolicy=idle\n' > /etc/systemd/system/$s.service.d/openthinrdp.conf
done
systemctl unmask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
exit 0
