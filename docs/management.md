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

Removing a key from the files does not reset it on the devices: set it explicitly to the value you want.

The Windows manager (`management/windows/OpenThinRDP-Manager.cmd`) shows the devices, their status and events,
and edits these files with the same validation, a backup of every file it overwrites and a change log.
Before saving `common.conf` it lists the devices that would reject it.

## SSH keys

With `SSH=on`, the `admin` account accepts only the keys in `/etc/openthinrdp/authorized_keys`: from the image
(`image/site/authorized_keys`) or from `config\authorized_keys`. Removing `config\authorized_keys` after it
was used revokes those keys and brings back the image ones.

## Signed updates

Devices install a package from `updates\` only if `LATEST.txt` carries a valid signature of the key in
`/etc/openthinrdp/update-key.asc` (from `image/site/update-key.asc`), the hash matches, and the version is
newer than the installed one. Installation runs in the background and never interrupts a session: the new
kiosk starts at the next sign-in. Three failed attempts per version at most.

Create the key once, on a machine you trust, and keep the private part offline:

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
