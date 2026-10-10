# OpenThinRDP

A thin client operating system for Windows Remote Desktop, built on Debian 13 and FreeRDP 3.

Turn small PCs or old thin clients into kiosks that boot straight into a sign-in form, connect through an
RD Connection Broker to the user's desktop, and are managed from a shared folder: status of every device,
central settings, signed updates. No agent, no management server, no cloud.

It grew out of a real migration away from a commercial thin client OS, on a fleet of Dell OptiPlex 3000 Thin
Clients connected to a Windows 11 VDI on Hyper-V; the system it comes from runs there in production every day.

> **Status: alpha (0.1).** The code comes from a system in production, but this generic version is new.
> Test it on one device before you roll it out.

[Leggimi in italiano](README.it.md)

## What it does

- **Sign-in form, then full screen remote desktop.** Boots in a few seconds with your logo, no desktop, no
  shell. Retries, fallback brokers, clear messages for "no network", "broker not reachable", "the virtual
  machine does not start", wrong password (never retried, so accounts are not locked).
- **Reconnects by itself** after network drops, and warns before taking over a session that is open on
  another device.
- **USB done right for VDI.** Webcams with their microphone, signature keys, tachograph and other special
  devices go to Windows as whole USB devices, also when plugged in during the session. Keyboards, mice, touch
  screens, hubs and network adapters stay local; smart card readers go through the smart card channel.
  Touch screens work as touch in Windows.
- **Management folder (SMB).** Each device writes its status and event log; you read them in a Windows
  manager (`management/windows`) or as a CSV. Settings for all devices or a single one are files in the same
  folder. Updates are signed with your OpenPGP key and installed by the devices themselves, never during a
  session.
- **Settings dialog on the device** (optionally behind a PIN): broker, network (DHCP, static, Wi-Fi),
  management folder, USB mode, web button, power schedule, language.
- **Power schedule and Wake-on-LAN**, Debian security updates (FreeRDP excluded), screen always on, monitors
  that are switched on late handled.
- **Web button**: a web app, free browsing, or a full screen kiosk page, with Chromium.
- **Experimental UDP transport** with a FreeRDP build that supports it (see `docs/udp.md`).
- English and Italian interface; more languages are one file each.

## Quick start

1. Build the image (Linux with Docker or Podman):
   ```
   cp -r image/site.example image/site      # then edit image/site/site.conf and build.conf, add your logo
   image/build.sh
   ```
   The result is `out/openthinrdp-<version>.iso`. See [docs/building.md](docs/building.md).
2. Write it to a USB stick (any raw image writer) and boot the thin client from it. The automatic install
   **wipes the first disk without asking**.
3. At the first start the settings dialog opens: set the broker and the rest, or let the central settings do it.

## Documentation

- [docs/configuration.md](docs/configuration.md): every setting.
- [docs/management.md](docs/management.md): the management folder, central settings, SSH keys, signed updates.
- [docs/building.md](docs/building.md): building and customizing the image.
- [docs/security.md](docs/security.md): security model and known limits.
- [docs/hardware.md](docs/hardware.md): tested hardware and firmware settings.
- [docs/udp.md](docs/udp.md): the experimental UDP transport.

## Layout

| Folder | Content |
|---|---|
| `rootfs/` | everything installed on the thin client (`/opt/openthinrdp`, udev rules, systemd units) |
| `image/` | the ISO build (live-build in a container) and the example site folder |
| `management/windows/` | the Windows manager (PowerShell, no installation) |
| `management/publish/` | building and signing update packages |
| `tests/` | tests that run in a Debian container |

## Contributing

Issues and pull requests are welcome. Please describe the hardware and the Windows side (broker, session
host version) for anything related to connections or devices. Run `tests/run-tests.sh` (see its header).

Security problems: please report them privately, see [SECURITY.md](SECURITY.md).

**Wanted: a logo.** The current one is a quick placeholder. If you can design a better one (boot splash and a
small version for the dialogs), open an issue or a pull request: you will be credited here.

## License

Apache License 2.0, see [LICENSE](LICENSE). OpenThinRDP uses FreeRDP (Apache 2.0) and Debian packages under
their own licenses. Windows and Remote Desktop are trademarks of Microsoft; this project is not affiliated with
Microsoft.
