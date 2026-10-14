# Changelog

Every release, newest first. **Security** marks what every device should get at once.
Downloads and signed update packages: [releases](https://github.com/OpenThinRdp/openthinrdp/releases).

## Unreleased

- **A USB device that hangs no longer ends the session** ([#10](https://github.com/OpenThinRdp/openthinrdp/issues/10)).
  Windows started the devices passed whole together with the display of the session; a USB stick that hung at
  start held Plug and Play for 60 s and Windows closed the session ("display driver not ready", reported to
  FreeRDP as [#13719](https://github.com/FreeRDP/FreeRDP/issues/13719)), and at the second time the kiosk took it
  for a session taken over and switched the device off. The devices passed whole now arrive 15 s after the
  desktop: their hub port is off while the session starts (`usb-hold.sh`), then on again, so for Windows they are
  plugged in with the session running and a device that hangs fails on its own. If anything goes wrong the ports
  come back on by themselves after 2 minutes.

## 0.1.8 (2026-10-14)

- **A USB network adapter works as soon as it is plugged in** ([#8](https://github.com/OpenThinRdp/openthinrdp/issues/8)).
  It used to stay without an address until the settings were saved: the udev rule matched the adapter's name
  before udev renamed it (`eth0`/`usb0`, then `enx…`), so it never matched a USB adapter; at boot an adapter
  appearing while the settings were being applied was configured by nobody; and the address request started in
  the background was killed with the udev job. Plugged in with the device running or present at boot, it now gets
  its address within seconds, without touching the adapter in use. A Wi-Fi adapter whose driver loads late is
  picked up the same way.
- **Wi-Fi survives kernel updates** ([#7](https://github.com/OpenThinRdp/openthinrdp/issues/7)). The initramfs
  built for the device included the Wi-Fi driver without the part it loads later (Intel: `iwlwifi` without
  `iwlmvm`), so after the next kernel update a device on Wi-Fi came up with no Wi-Fi adapter at all and no network.
  Only wired and graphics drivers go in now; devices set up by older versions get the Wi-Fi drivers taken out at
  the next boot (the boot after that has the adapter back).
- The DROPPED event names why FreeRDP ended the session (its last connection error), not the channels that
  fail while the connection closes behind it (it named a smart card channel after the UDP tunnel broke down).

## 0.1.7 (2026-10-13)

- **Manager: Problems tab.** The event logs of all devices read together for a period and grouped: failed sign-in
  attempts by broker, dropped sessions by cause, refused sign-ins, sessions taken over, failed updates. The same
  problem on 3 or more devices is highlighted ([management.md](docs/management.md#problems-across-the-fleet)).
- **`USB_MODE=disks` keeps USB sticks on the thin client also when they are plugged in during a session.** The
  class filter did not include storage, so FreeRDP took a stick plugged in mid-session as a whole USB device and
  Windows got a raw disk without a drive letter instead of the shared drive. Devices listed in `USB_REDIRECT` still
  go whole.
- **Waiting for Windows instead of failing.** When the broker answers but the virtual machine refuses the desktop
  (it is restarting or installing a Windows update), the device no longer spends its attempts and ends on "desktop
  not available", nor reconnects every few seconds to sessions that Windows drops after ~22 s while it finishes the
  update. It shows *Waiting for Windows* with the minutes elapsed and a Cancel button, tries again every 20 s, and
  connects as soon as the desktop is ready (up to 20 minutes). One event when the wait starts, one every 5 minutes.
- **Dropped sessions keep their log.** The FreeRDP log of a dropped session stays as `/tmp/kiosk.log.prev` (the
  reconnection starts a new one at once) and the DROPPED event ends with its last error, so the cause can be read
  afterwards, also in the manager's Problems tab.
- Updates from GitHub are checked every 3 hours instead of 6.
- The central settings are not applied while an update is installing (a valid setting could be rejected with half
  the files updated).

## 0.1.6 (2026-10-13)

- **Session taken over from another device.** Windows 11 ends the session of the device left behind with code 1, the
  same as a VM shutdown (measured directly on the VM and through the broker), never with 5. The device now checks
  whether the VM still answers: if it does, it shows "Session opened elsewhere" with Resume here, instead of the
  shutdown page that switched it off.
- **Startup progress.** The progress screen showed each step one step late (it read one line per wake-up), so it
  stayed on "Connecting to the broker" while the broker was starting the VM. Every step now shows at once, and after
  5 s on the broker it says the virtual machine is being started.
- **Kerberos behind a broker alias.** With `RDP_AUTH=negotiate` the device connects to one of the brokers behind
  a round-robin name by that broker's own name: the Kerberos ticket was otherwise asked for whichever broker the
  Kerberos library looked up, and the other one refused it. NTLM-only (`RDP_AUTH=ntlm`) is no longer needed there,
  and the device keeps two ways to sign in instead of one.
- **Manager: Check permissions.** Lists what the devices' account can change in the management folder
  besides `status\`, through which group, and what every user can change there
  ([management.md](docs/management.md#account)).
- Devices report the account of the management folder (`MGMT_ACCOUNT`, never the password).
- `SUMMARY.csv` moves into `status\`, so the devices need write access there only.

## 0.1.5 (2026-10-12)

- **The installer asks before erasing the disk.** *Install* shows the internal disk it is going to use and
  the partitions it will write, and asks ("No" preselected); old LVM volumes or software RAID on that disk are
  never removed without a question either. *Unattended install*, a separate entry of the boot menu, keeps the
  old behaviour for rollouts on known hardware.
- **FreeRDP: pull request #13608 unchanged, no patches of ours.** The author took our two fixes into the pull
  request (ten SYN attempts, and the root cause of the false "stream is stuck" on lossy lines), which also
  removes a 1 s freeze at every wrap of the channel sequence under loss: with 70% of the packets lost the
  session now keeps 18-19 frames per second instead of 9-13.
- **Settings PIN salted and stretched** (PBKDF2-SHA256, 600,000 iterations) when set from the manager; a PIN
  of 0.1.4 and earlier keeps working.
- Docs: the devices' account needs write access to `status\` only ([management.md](docs/management.md#account));
  replacing or revoking the release key through the update channel ([SECURITY.md](SECURITY.md)).
- FreeRDP gets 20 s instead of 30 to bring a connection up: a broker that accepts the connection and then hangs
  costs this much on every attempt before the next broker is tried. Still above the 15 s a broker took to prepare
  a virtual machine.
- The system tests (93) and a shell syntax check run in Debian 13 on every push and pull request
  ([CI](https://github.com/OpenThinRdp/openthinrdp/actions/workflows/tests.yml)).

## 0.1.4 (2026-10-12)

- **The project moved to the OpenThinRDP organization**: https://github.com/OpenThinRdp/openthinrdp, website
  https://openthinrdp.github.io/. The old addresses redirect, and devices already installed keep updating.

- **Security: FreeRDP 3.32.2**, the security release of 2026-10-12, with the UDP transport (pull request #13608)
  on top. The USB fixes #13674, #13679 and #13618 are part of 3.32.2.
- **UDP holds on lossy lines.** We found and fixed a bug in the UDP transport: after the channel sequence wrapped,
  a wrong elapsed time (an unsigned difference going below zero) made the client believe the stream had been stuck
  for ages, and it ended the connection within seconds whenever packets were being lost. Now the session keeps
  **20 frames per second with 50% of the packets lost and 9 with 70%**, and still draws at 80%; TCP is down to
  0.6 at 20%. The tunnel is also set up with ten attempts instead of four. Both fixes are proposed to FreeRDP in
  pull request #13608. See [docs/udp.md](docs/udp.md).
- FreeRDP gets 30 s instead of 9 to bring a connection up and to wait for the TCP connection beside the UDP
  tunnel (`/timeout`): a broker preparing a virtual machine in 15 s no longer makes the first attempt fail, and on
  a very lossy line the TCP connection is not given up while the UDP tunnel still carries the session.
- **Fix: no microphone in meetings with a webcam.** A webcam was passed to Windows as a whole USB device, and
  Windows keeps the microphone of such a device in the console session: Teams and Zoom in the remote session found
  no microphone at all. Webcams and USB headsets now stay on the thin client: the camera goes through the RDP
  camera channel ([MS-RDPECAM]), the microphone and the speaker through the RDP audio channels. Devices plugged in
  during the session follow the same rule, and a webcam an earlier version had passed over USB is given back to
  the thin client by itself (its Linux drivers are attached again).
- **Updates installed during a session take effect when it is over**: as soon as the device is back to the
  sign-in screen, or a new connection starts, the screen reloads with the new version (before: at the next start).
- The mouse pointer on the kiosk screens (sign-in, progress, messages) hides while the mouse is still and comes
  back as soon as it moves; in the remote desktop it is Windows' own pointer as before.
- Fix: a device moved to another management folder by `MGMT_SHARE` in the common settings went back to the
  folder of its image at the next report, and kept bouncing between the two.

## 0.1.3 (2026-10-12)

In production: this version runs a fleet of thin clients converted in place, updated from their management folder.

- **New screens for the user** (GTK, full screen, on the background of the site): sign-in with the clock and date,
  information and settings small in the top right corner, power with **Restart** and **Shut down** bottom right,
  the web button bottom left; desktop start with a progress bar that follows the real steps (broker, redirection,
  desktop on screen); errors, no network, session open elsewhere, session taken over, end of session with a
  countdown. Settings, diagnostics and PIN stay simple dialogs (administrators only).
- **Software updates**: a notice with the progress in the top right corner while one installs; **Shut down
  during an update** shows it full screen and switches off when it is done (before, it interrupted the install).
- The boot screen always shows the picture and colors of the image (OpenThinRDP's, or yours when you build your
  own image); the picture of the management folder is the background of the sign-in screen, which is drawn
  again as soon as a new one arrives. In the manager the button is now **Logo and background...**.
- Devices still showing the provisional logo of 0.1.0 get the current one (only exact project pictures are
  replaced, never those of your own image).
- **FreeRDP**: the USB fix for a client hanging on disconnect is now [FreeRDP#13679](https://github.com/FreeRDP/FreeRDP/pull/13679)
  (by the FreeRDP maintainer, from our #13677); [#13674](https://github.com/FreeRDP/FreeRDP/pull/13674) was approved.
- Manager: a picture whose width already fit was not scaled to the height.
- Day and month of the sign-in screen follow `LANGUAGE`, not the system locale.

## 0.1.2 (2026-10-12)

- **Fix**: update packages always carry 755/644 modes. The 0.1.1 package was built with umask 002, and a device
  that installed it got a group-writable `/etc`, so sshd refused every key. Installing 0.1.2 repairs it.
  The 0.1.1 package was withdrawn; the 0.1.1 ISO was not affected.
- The README links always point to the latest release.

## 0.1.1 (2026-10-12)

- **Security**: no text consoles. Ctrl+Alt+F1..F12 and Ctrl+Alt+Backspace do nothing in the kiosk, no spare
  consoles with a login prompt, the `kiosk` account is locked. In 0.1.0 `kiosk` had no password: anybody at the
  keyboard could get a shell with Ctrl+Alt+F2. Devices updated from 0.1.0 are fixed too.
- Secrets (Wi-Fi key, management folder password) are never printed back, only their hash.
- Logo and boot image from the Windows manager, for every device or for one (`config\branding\`); the boot
  splash follows, also when only the colors change.
- Diagnostics button (ℹ) on the sign-in form, without a PIN: network, brokers, time, management folder, events.
- A new device names itself `thinclient-` + the last 6 digits of its MAC address.
- Management folder account in the settings dialog and in the central settings (`MGMT_USER`, `MGMT_PASSWORD`).
- `MULTIMON=auto|off`: one remote desktop over every monitor.
- Certificate authorities of the site are trusted by the system too.
- Settings labels with a colon (`hh:mm`, `VID:PID`) were cut short since 0.1.0.
- README: direct connection to a Windows PC, what comes next.

## 0.1.0 (2026-10-11, pre-release)

- First public version: kiosk with FreeRDP and the UDP transport, USB for VDI, management from a shared folder
  with a Windows manager, signed updates from GitHub or the folder, ISO with a live system and automatic
  installation.
