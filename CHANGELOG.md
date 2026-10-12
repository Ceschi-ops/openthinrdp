# Changelog

Every release, newest first. **Security** marks what every device should get at once.
Downloads and signed update packages: [releases](https://github.com/OpenThinRdp/openthinrdp/releases).

## Unreleased

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
