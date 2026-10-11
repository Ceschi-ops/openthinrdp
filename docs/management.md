# Management folder

One SMB share (a folder on any Windows or Samba file server) is the whole management system. Every device
mounts it every 5 minutes, at boot and at every new event, writes its status and reads settings and updates.

```
\\fileserver\thinclients\
  SUMMARY.csv                  one line per device (rewritten by the devices)
  status\<hostname>.txt        status: KEY=value lines + last errors and events
  status\<hostname>-events.log event log
  config\common.conf           settings for every device
  config\<hostname>.conf       settings for one device (wins over common.conf)
  config\authorized_keys       SSH public keys of the administrators (optional)
  config\backup\, changes.log  written by the Windows manager
  updates\LATEST.txt(.sig)     signed update index, and the packages
```

## Account

The devices log in with `/etc/openthinrdp/smb.cred` (put it in `image/site/smb.cred`):

```
username=svc-thinclients
password=...
domain=EXAMPLE
```

Because this file is in every image, use an account that can **only** read and write this folder: not a
member of Domain Users, Modify on the folder, nothing else. Check from a device that the account cannot list
or write anything outside it.

## Central settings

`config\common.conf` and `config\<hostname>.conf` hold the same keys as [configuration.md](configuration.md).
Files saved on Windows are fine (BOM, CRLF, spaces around `=`, `#` and `;` comments). A device:

- merges common, then its own file, over its current settings;
- validates the result with the same rules as the settings dialog, and applies it only if something changed;
- refuses the whole result if anything is invalid (event "central configuration REJECTED", reported once),
  keeping the previous settings;
- keeps the last good copy when the folder is unreachable.

Central values win: a key in the central files is written into the device settings at every run (every 5
minutes and at boot), so a change made in the settings dialog of a device lasts only until then. Keys that the
central files do not set stay as set on the device.

Removing a key from the central files gives it back to the device defaults: the device drops it from its
settings and follows `site.conf` or the project defaults again, like a device installed today. If the result
would not be valid (e.g. removing `WEB_URL` while `WEB_BUTTON=app` stays), the key is kept, the event is logged
once and the release is retried at every run.

The Windows manager (`management/windows/OpenThinRDP-Manager.cmd`) shows the devices, their status and events,
and edits these files with the same validation, a backup of every file it overwrites and a change log.
Before saving `common.conf` it lists the devices that would reject it.

## SSH keys

With `SSH=on`, the `otradmin` account accepts only the keys in `/etc/openthinrdp/authorized_keys`: from the image
(`image/site/authorized_keys`) or from `config\authorized_keys`. Removing `config\authorized_keys` after it
was used revokes those keys and brings back the image ones.

## Signed updates

Software updates (kiosk, FreeRDP with UDP, fixes) come from where `UPDATE_FROM` says:

| `UPDATE_FROM` | Source | Signature accepted |
|---|---|---|
| `github` (default) | the latest release of `UPDATE_GITHUB` (not pre-releases), asked every 6 hours | the project key only |
| `share` | `updates\` in the management folder: you decide when the devices get a version | the project key, or your own key |
| `off` | none | |

The project key is `/opt/openthinrdp/keys/openthinrdp-release.asc`, in the image and in every update. A
device installs a package only if `LATEST.txt` carries a valid signature, the hash of the package matches, and
the version is newer than the installed one (or than the image, when no update was installed yet).
Installation runs in the background and never interrupts a session: the new kiosk starts at the next sign-in.
Three failed attempts per version at most. The status file shows the source (`UPDATE_FROM`) and the result.

**A fleet you manage**: set `UPDATE_FROM=share` in `config\common.conf` and `UPDATE_FROM=github` in the
`config\<hostname>.conf` of one or two pilot devices. When the pilots are fine with a release, copy its three
files (`LATEST.txt`, `LATEST.txt.sig`, `openthinrdp-update-<version>.tar.gz`) into `updates\`: every device
checks the project signature itself, nothing has to be re-signed.

**Your own packages** (changes of yours, or your site files) need your own key, built into your image as
`/etc/openthinrdp/update-key.asc`. Create it once, on a machine you trust, and keep the private part offline:

```
gpg --quick-gen-key "Thin client updates <it@example.com>" ed25519 sign never
gpg --armor --export it@example.com > image/site/update-key.asc
```

Publish a version (Linux, WSL or Git Bash with Gpg4win; the folder mounted or reachable as a path):

```
management/publish/make-update.sh -v 2026.10.1 -k it@example.com -o /mnt/thinclients
```

`-d <folder>` adds `.deb` files (e.g. your own FreeRDP build, installed only when newer); `-s image/site`
ships your site files too. To keep FreeRDP as it is on one device, create `/etc/openthinrdp/freerdp-pinned`
with the reason inside.
