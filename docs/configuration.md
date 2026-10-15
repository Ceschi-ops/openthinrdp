# Configuration

Every setting is a `KEY=value` line. A device reads them in this order, the first file that has the key wins:

1. `/etc/openthinrdp/openthinrdp.conf`: this device (settings dialog ⚙, central settings)
2. `/etc/openthinrdp/site.conf`: your organization, built into the image from `image/site/site.conf`
3. `/opt/openthinrdp/defaults.conf`: project defaults

An empty value in a higher file clears a lower one on purpose (e.g. `TITLE=` in the device file).

The device file is written by the settings dialog **and** by the central settings, and the central settings
win: in practice the order is `config\<hostname>.conf` > `config\common.conf` > settings dialog > `site.conf` >
defaults. A key removed from the central files goes back to `site.conf`/defaults, so all devices stay alike
(see [management.md](management.md)).
Values are validated by `save-config.sh` with the same rules wherever they come from (dialog, central
settings, manager); invalid central settings are refused as a whole and the previous ones stay.

The reference with comments is [`rootfs/opt/openthinrdp/defaults.conf`](../rootfs/opt/openthinrdp/defaults.conf).

## Remote desktop

| Key | Default | Meaning |
|---|---|---|
| `BROKER` | | RD Connection Broker, or directly a session host or any Windows PC with Remote Desktop on: name or IP. Empty = the settings dialog opens at start |
| `BROKER_FALLBACK` | | other brokers, space separated, tried in turn from the 3rd attempt |
| `DOMAIN` | | Windows domain of the users |
| `LOAD_BALANCE_INFO` | | RDS collection, as `loadbalanceinfo` in the .rdp file, e.g. `tsv://VMResource.1.VDI` |
| `DEFAULT_USER` | | user name pre-filled in the sign-in form |
| `TRANSPORT` | `auto` | `auto` = UDP, TCP when UDP is blocked or fails; `udp` = UDP only; `tcp` = TCP only. See [udp.md](udp.md) |
| `RDP_AUTH` | `negotiate` | `negotiate` = Kerberos, NTLM when Kerberos is not available (`DOMAIN` must be the full DNS name, e.g. `example.local`); `kerberos` = Kerberos only: the sign-in fails instead of falling back to NTLM (for domains that turned NTLM off, and to see a broken Kerberos setup at once); `ntlm` = NTLM only. Behind an alias shared by several brokers the device connects to one of them by its own name, so that the Kerberos ticket is for the server it talks to |
| `RDP_CERT` | `tofu` | `ignore`, `tofu` (trust on first use) or `verify` |
| `RDP_GFX` | `progressive,AVC420:off,AVC444:off` | `/gfx` options. Without a GPU on the server this keeps text pixel exact |
| `RDP_KEYBOARD` | | keyboard layout id for Windows, e.g. `0x00000409`. Empty = taken from the X keyboard |
| `MULTIMON` | `auto` | `auto` = every monitor when more than one is connected (`/multimon`), `off` = only the main one |
| `RDP_EXTRA` | | extra xfreerdp3 options (letters, digits, `/:+,._=#-` and spaces only) |
| `SESSION_THRESHOLD` | `10` | a session that ends within these seconds counts as a failed attempt |
| `SHUTDOWN_SECS` | `10` | after the user disconnects, switch off after these seconds (0 = never) |

The device switches off only after a deliberate end (disconnect, sign out, VM shut down by an administrator).
Every other ending (network drop, crash, server restart) reconnects without asking. A session taken over by
another device shows "Session opened elsewhere" with *Resume here* instead of reconnecting. When the broker
answers but the virtual machine refuses the desktop (it is restarting or installing a Windows update), the device
shows *Waiting for Windows* with a Cancel button and tries again every 20 s, without counting attempts, for up to
20 minutes.

## USB

| Key | Default | Meaning |
|---|---|---|
| `USB_MODE` | `all` | `all` = every device except keyboard, mouse, touch screen, hub, Bluetooth adapter, network adapter, smart card reader, webcam and USB headset goes to Windows as a whole device (RemoteFX USB redirection). `disks` = USB sticks stay on the thin client, are mounted there and appear in Windows as redirected drives (`\\tsclient`), also when plugged in during a session (since 0.1.7). `auto` = device by device: a device that is only storage (every interface mass storage: a stick, a card reader, a disk) as a drive, as with `disks`; a device with storage and something else (an instrument with a serial port, a key with its own Windows driver) whole, as with `all`, so that its driver gets all of it. Plugged in during a session, `auto` works as `disks`: FreeRDP's filter sees a class on any interface |
| `USB_REDIRECT` | | `VID:PID` list always passed whole, in every mode (smart card readers excepted: they always go through the smart card channel) |

A USB stick passed whole (`USB_MODE=all`) gets its drive letter from Windows inside the session of the user it is
redirected to, as on a physical PC. That letter is not visible to services or to other sessions, so a tool running
as SYSTEM sees no letter: this is how Windows works, not something to fix by assigning letters.

Webcams and USB sound devices (headsets, speakerphones) stay on the thin client: the camera goes through the RDP
camera channel and appears in Windows as "*name* (redirected)", the microphone and the speaker through the RDP
audio channels ("Remote Audio"). Passed as whole USB devices they reach Windows as devices of the console session,
and the apps of the remote session see no microphone at all. When there is no USB microphone the thin client's
own input is used. A device listed in `USB_REDIRECT` is still passed whole.

## Network

| Key | Default | Meaning |
|---|---|---|
| `NETMODE` | `dhcp` | `dhcp` or `static` |
| `IPADDR`, `NETMASK`, `GATEWAY` | | static address (static mode only) |
| `DNS1`, `DNS2` | | DNS servers; empty = from DHCP. Required with a static address |
| `NTP` | | time servers; empty = Debian pool |
| `HOSTNAME` | `thinclient-` + the last 6 digits of the MAC address | name of the device (the system host name, not stored in the settings file) |
| `WIFI` | `off` | `on` = use Wi-Fi when no cable is connected |
| `WIFI_SSID`, `WIFI_COUNTRY` | | network name, regulatory country (two letters) |
| `WIFI_PSK` | | password or 64-hex key. Only in central settings or the dialog; stored only in `/etc/wpa_supplicant` |

## Management

| Key | Default | Meaning |
|---|---|---|
| `MGMT_SHARE` | | management folder, e.g. `\\fileserver\thinclients`, see [management.md](management.md) |
| `MGMT_USER` | | account of the management folder: `user`, `DOMAIN\user` or `user@domain`. Empty = `smb.cred` of the image |
| `MGMT_PASSWORD` | | its password. Only in central settings or the dialog; stored only in `/etc/openthinrdp/smb.cred` |
| `SECURITY_UPDATES` | `on` | Debian security updates, never FreeRDP, never a reboot |
| `TPM_SECRETS` | `on` | with a TPM 2.0: folder password, Wi-Fi key and SSH host keys kept encrypted in it ([security.md](security.md)); `off` = root-only files, and back out of the TPM at the next start |
| `UPDATE_FROM` | `github` | OpenThinRDP software updates: `github` (signed releases, checked every 3 hours), `share` (`updates\` of the management folder) or `off`, see [management.md](management.md#signed-updates) |
| `UPDATE_GITHUB` | `OpenThinRdp/openthinrdp` | repository of the releases, `owner/repository` (for a fork) |
| `SSH` | `off` | `on` = SSH for the `otradmin` account, key login only |
| `REMOTE_SCREEN` | `on` | `off` = no remote screen from the manager ([management.md](management.md#remote-screen)); it needs `SSH=on` |

## Web button and kiosk page

| Key | Default | Meaning |
|---|---|---|
| `WEB_BUTTON` | `none` | `app` (only `WEB_URL` and `WEB_ALLOW`), `browser` (free browsing), `kiosk` (page full screen at power on) |
| `WEB_LABEL` | `Web` | button label |
| `WEB_URL` | | web address for `app` and `browser` |
| `WEB_ALLOW` | | other sites allowed in `app` mode (URL prefixes) |
| `KIOSK_URL` | | the kiosk page. The sign-in form shows for 5 s first: touching anything keeps it |
| `KIOSK_RELOAD_MIN` | `10` | reload the page every N minutes when idle (0 = never) |

## Power schedule

| Key | Default | Meaning |
|---|---|---|
| `POWER_ON_TIME` | | `hh:mm`, RTC wake alarm (firmware support needed, see [hardware.md](hardware.md)) |
| `POWER_OFF_TIME` | | `hh:mm`, with a 60 s warning that can be cancelled; waits for an open session to end |
| `POWER_ON_DAYS` | `1234567` | 1 = Monday ... 7 = Sunday |

## Look and language

| Key | Default | Meaning |
|---|---|---|
| `LANGUAGE` | `en` | `en`, `it` (a file in `/opt/openthinrdp/lang/`) |
| `KEYBOARD` | `us` | X11 layout |
| `TITLE` | `Remote desktop` | window titles |
| `LOGO` | `/opt/openthinrdp/branding/logo.png` | logo in the dialogs. A logo in the management folder wins, see [management.md](management.md#logo-and-background-picture) |
| `BG_TOP`, `BG_BOTTOM` | `#1b2733`, `#000000` | background gradient (boot splash and behind the form) |
| `SUPPORT_TEXT` | | extra line in error messages, e.g. "Call the IT desk, ext. 123" |
| `SETTINGS_PIN_SHA256` | | protects the settings dialog. Set it from the manager, which stores `pbkdf2-sha256:<iterations>:<salt>:<key>` (salted PBKDF2-SHA256); by hand: `python3 -c 'import hashlib,os,sys; s=os.urandom(16); print("pbkdf2-sha256:600000:"+s.hex()+":"+hashlib.pbkdf2_hmac("sha256",sys.argv[1].encode(),s,600000).hex())' 123456`. The plain SHA-256 of 0.1.4 and earlier still works. Never shown in the status files |

`HOSTNAME`, `DEFAULT_USER`, `NETMODE` and `IPADDR` identify a device: in central settings they are accepted
only in `config\<hostname>.conf`, never in `config\common.conf`.
