# Building the image

Needs a Linux machine (or VM) with Docker or Podman able to run privileged containers, and about 15 GB of
disk. The build runs live-build inside a `debian:trixie` container and takes 10-20 minutes.

```
cp -r image/site.example image/site
# edit image/site/build.conf and image/site/site.conf, add logo.png / splash.png and the rest
image/build.sh
```

Result: `out/openthinrdp-<version>.iso` and its `.sha256`. `image/site/` is ignored by git: it holds your
credentials and keys.

With `FREERDP_FROM=openthinrdp` the build first needs the FreeRDP packages of `image/freerdp/freerdp.conf`:
it downloads the prebuilt ones (checked against `image/freerdp/SHA256SUMS`) or, when they are not published,
builds them with `image/freerdp/build-debs.sh` (15-40 minutes, once: they stay in `out/freerdp/`).

## The site folder

See [image/site.example/README.md](../image/site.example/README.md). In short:

- `build.conf`: `FIRMWARE` (`all`, the default: runs on any PC; `thinclient`: only the usual thin client firmware,
  about 600 MB less), `INCLUDE_BROWSER`, installer language (`LOCALE`), `TIMEZONE`, `KEYBOARD`, `ADMIN_PASSWORD_HASH` (console password
  of `otradmin`, from `mkpasswd -m yescrypt`; empty = SSH key only), `FREERDP_FROM` (`openthinrdp`, the
  default: FreeRDP with UDP, see [udp.md](udp.md); `backports`, `debian` or `site`), `AUTO_INSTALL`.
- `site.conf`: default settings of every device.
- `logo.png` (~200 px, dialogs), `splash.png` (~640 px, transparent, boot screen).
- `ca/*.crt`: certificate authorities for the web button.
- `smb.cred`, `update-key.asc`, `authorized_keys`: management (see [management.md](management.md)).
- `debs/*.deb`: your own packages, e.g. a FreeRDP build.

## Installing

Write the ISO to a USB stick with any raw image writer and boot from it (UEFI). The default menu entry starts
the live system; **Install** runs the automatic installation, which **wipes the first disk without asking**
and reboots. With `AUTO_INSTALL=no` the usual Debian installer questions are asked.

At the first boot of the installed system the device shrinks its initramfs to its own hardware and makes the
boot silent; the settings dialog opens if no broker is set.

## Accounts

| Account | Purpose |
|---|---|
| `kiosk` | runs the X session and the kiosk, logs in automatically, no password, may only run `save-config.sh` as root |
| `otradmin` | administration: SSH with a key (`SSH=on`), console with `ADMIN_PASSWORD_HASH`, sudo |
| `root` | locked |
