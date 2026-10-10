# Security model

A thin client is a public-facing device: anyone can sit at it. OpenThinRDP assumes that whoever is at the
keyboard is untrusted and that the management folder is readable by the devices only.

## What protects what

- **No shell for the user.** Openbox without menus or key bindings; the only programs are the sign-in form,
  FreeRDP and, if enabled, Chromium with policies (no downloads, extensions, developer tools, guest or
  incognito windows; in `app` mode only the allowed sites).
- **Settings dialog behind a PIN** (`SETTINGS_PIN_SHA256`). Without a PIN anyone at the device can point it to
  another broker. The "Terminal" button of the dialog opens a shell as the `kiosk` user.
- **`kiosk` has one root privilege:** `save-config.sh`, which validates every value before touching the system.
- **No password in the image.** `root` is locked; `admin` has no password unless you set a hash in
  `build.conf`; SSH is off by default and accepts only keys.
- **Signed updates.** A package is installed only with a valid signature of your key (verified with `sqv`)
  and a matching hash; never an older version.
- **Credentials.** The user's password goes to FreeRDP on its command line, which FreeRDP overwrites with `*`
  right after start (visible to the local `kiosk` account for a moment at most). The Wi-Fi key is stored only
  in `/etc/wpa_supplicant` (root, 600) and never reported. The settings PIN hash is never written to the status
  files.

## Known limits

- `smb.cred` is in every image: a stolen device gives its holder that account. Give it access to the
  management folder only, and change the password if a device is lost.
- The management folder is trusted: whoever can write it can change the settings of every device (within
  the validation rules) and can make devices mount another folder. Updates still need your signature.
- `RDP_CERT=ignore` accepts any server certificate. The default `tofu` trusts the first certificate seen per
  server; `verify` requires certificates trusted by the system.
- The PIN is a speed bump, not a vault: a short PIN hashed with SHA-256 can be brute-forced by anyone who
  gets the device settings file.
- Physical access to the disk (no encryption) gives access to everything stored on the device.

Report security problems privately to the maintainers (GitHub security advisories) rather than in a public issue.
