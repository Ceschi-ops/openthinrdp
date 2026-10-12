# Changelog

Every release, newest first. **Security** marks what every device should get at once.
Downloads and signed update packages: [releases](https://github.com/Ceschi-ops/openthinrdp/releases).

## Next

- The boot screen always shows the picture and colors of the image (OpenThinRDP's, or yours when you build your
  own image); the picture of the management folder is the background of the sign-in form only. A device that
  had put it on the boot screen with 0.1.1 or 0.1.2 gets the image's own back. In the manager the button is now
  **Logo and background...**.

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
