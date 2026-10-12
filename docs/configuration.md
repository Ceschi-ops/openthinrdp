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
| `RDP_AUTH` | `negotiate` | `ntlm` = NTLM only (when Kerberos fails on the broker redirect) |
| `RDP_CERT` | `tofu` | `ignore`, `tofu` (trust on first use) or `verify` |
| `RDP_GFX` | `progressive,AVC420:off,AVC444:off` | `/gfx` options. Without a GPU on the server this keeps text pixel exact |
| `RDP_KEYBOARD` | | keyboard layout id for Windows, e.g. `0x00000409`. Empty = taken from the X keyboard |
| `MULTIMON` | `auto` | `auto` = every monitor when more than one is connected (`/multimon`), `off` = only the main one |
| `RDP_EXTRA` | | extra xfreerdp3 options (letters, digits, `/:+,._=#-` and spaces only) |
| `SESSION_THRESHOLD` | `10` | a session that ends within these seconds counts as a failed attempt |
| `SHUTDOWN_SECS` | `10` | after the user disconnects, switch off after these seconds (0 = never) |

The device switches off only after a deliberate end (disconnect, sign out, VM shut down by an administrator).
Every other ending (network drop, crash, server restart) reconnects without asking.

## USB

| Key | Default | Meaning |
|---|---|---|
| `USB_MODE` | `all` | `all` = every device except keyboard, mouse, touch screen, hub, network adapter, smart card reader, webcam and USB headset goes to Windows as a whole device. `disks` = USB sticks as network drives |
| `USB_REDIRECT` | | `VID:PID` list always passed whole, also in `disks` mode |

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
| `UPDATE_FROM` | `github` | OpenThinRDP software updates: `github` (signed releases), `share` (`updates\` of the management folder) or `off`, see [management.md](management.md#signed-updates) |
| `UPDATE_GITHUB` | `OpenThinRdp/openthinrdp` | repository of the releases, `owner/repository` (for a fork) |
| `SSH` | `off` | `on` = SSH for the `otradmin` account, key login only |

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
| `SETTINGS_PIN_SHA256` | | protects the settings dialog: `printf 1234 \| sha256sum`. Never shown in the status files |

`HOSTNAME`, `DEFAULT_USER`, `NETMODE` and `IPADDR` identify a device: in central settings they are accepted
only in `config\<hostname>.conf`, never in `config\common.conf`.
