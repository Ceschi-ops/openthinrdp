# Security model

A thin client is a public-facing device: anyone can sit at it. OpenThinRDP assumes that whoever is at the
keyboard is untrusted and that the management folder is readable by the devices only.

## What protects what

- **No shell for the user.** Openbox without menus or key bindings; the only programs are the sign-in form,
  FreeRDP and, if enabled, Chromium with policies (no downloads, extensions, developer tools, guest or
  incognito windows; in `app` mode only the allowed sites).
- **No text consoles.** Ctrl+Alt+F1..F12 do not leave X (`DontVTSwitch`), there are no spare consoles with a
  login prompt (`NAutoVTs=0`), and the `kiosk` account is locked: it logs in automatically on tty1 only.
  (0.1.0 left `kiosk` with an empty password and the spare consoles on: anybody at the keyboard could get a
  shell with Ctrl+Alt+F2. Fixed in 0.1.1, also on devices updated from 0.1.0.)
- **Diagnostics without a PIN** (the ℹ button of the sign-in form): read only, it shows the network, the
  reachability of the remote desktop hosts and the last events, never a setting or a secret.
- **Settings dialog behind a PIN** (`SETTINGS_PIN_SHA256`). Without a PIN anyone at the device can point it to
  another broker. The "Terminal" button of the dialog opens a shell as the `kiosk` user.
- **`kiosk` has one root privilege:** `save-config.sh`, which validates every value before touching the system.
- **No password in the image.** `root` is locked; `otradmin` has no password unless you set a hash in
  `build.conf`; SSH is off by default and accepts only keys.
- **Signed updates.** A package is installed only with a valid signature (verified with `sqv`): the
  project key, or with `UPDATE_FROM=share` also your own key ([management.md](management.md#signed-updates)),
  and a matching hash; never an older version.
- **Credentials.** The user's password goes to FreeRDP on its command line, which FreeRDP overwrites with `*`
  right after start (visible to the local `kiosk` account for a moment at most). The Wi-Fi key is stored only
  in `/etc/wpa_supplicant` (root, 600) and the management folder password only in `/etc/openthinrdp/smb.cred`
  (root, 600); neither is ever reported or printed back (`save-config.sh --print` shows only their hash). The
  settings PIN hash is never written to the status files.

## Known limits

- `smb.cred` is on every device: a stolen device gives its holder that account. Give it write access to
  `status\` only and read access to the rest of the management folder ([management.md](management.md#account)):
  then that account cannot change the settings of the other devices nor offer them anything to install. Change
  the password if a device is lost (`MGMT_PASSWORD` in the central settings rotates it on every device that can
  still reach the folder).
- The management folder is trusted: whoever can write `config\` can change the settings of every device
  (within the validation rules) and can make devices mount another folder. Updates still need a valid
  signature (the project key, or your own key).
- `RDP_CERT=ignore` accepts any server certificate. The default `tofu` trusts the first certificate seen per
  server; `verify` requires certificates trusted by the system.
- The PIN is a speed bump, not a vault. The manager stores it salted and stretched (PBKDF2-SHA256, 600,000
  iterations, about 0.2 s per try on a thin client): a 6-digit PIN takes days to brute-force from a stolen
  settings file, a 4-digit one less than an hour, so use 6 digits or more. A PIN set by 0.1.4 or earlier is a
  plain SHA-256 and still works; set it again from the manager to store it the new way.
- Physical access to the disk (no encryption) gives access to everything stored on the device.

Report security problems privately to the maintainers (GitHub security advisories) rather than in a public issue.
