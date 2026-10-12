# UDP transport

Windows sends Remote Desktop graphics over UDP when the client supports MS-RDPEMT/RDPEUDP. Over TCP a busy
server or a lossy line makes the screen fall behind: every lost packet holds up everything after it. Over UDP
the server measures the line and lowers frame rate and quality instead, so the session stays responsive.

FreeRDP does not ship UDP support yet: it is under review upstream
([FreeRDP pull request #13608](https://github.com/FreeRDP/FreeRDP/pull/13608)). OpenThinRDP ships FreeRDP
built with it, so it works out of the box.

## Modes

`TRANSPORT`, per device or for all of them (settings dialog, central settings, manager):

| Value | Behaviour |
|---|---|
| `auto` (default) | UDP. When UDP is blocked, or fails during the session, FreeRDP goes on over TCP; the next connection tries UDP again |
| `udp` | UDP only. A connection that runs without UDP for 30 s is closed and opened again; after 3 in a row the device shows "UDP not available". For networks where UDP is known to work, and for testing |
| `tcp` | TCP only |

The kiosk runs FreeRDP with `/network:auto` for `auto` and `udp`, and with `-multitransport` for `tcp`. It does
not use `/auto-reconnect`: when FreeRDP's own reconnection fails it exits with the same code as an
administrator disconnect, and the device would stop. The kiosk reopens the session itself instead.

The `status\<hostname>.txt` line `TRANSPORT=auto (in use: udp)` shows what the session really uses.

## Server side

Nothing to install. UDP must be allowed:

- Group Policy *Computer Configuration > Administrative Templates > Windows Components > Remote Desktop Services
  > Remote Desktop Session Host > Connections > Select RDP transport protocols*: not configured, or "Use both
  UDP and TCP".
- UDP port 3389 open on the session hosts (Windows opens it by default) and on any firewall in between. The
  broker does not need it: it only redirects.

## The FreeRDP in the image

`image/freerdp/freerdp.conf` names the exact source: branch
[`openthinrdp-udp-13679`](https://github.com/Ceschi-ops/FreeRDP/tree/openthinrdp-udp-13679) of a FreeRDP fork, which is
FreeRDP master with:

- pull request #13608: the UDP transport;
- pull request #13674: a deadlock between USB hotplug and the closing of the USB channel;
- pull request #13679 (from our #13677): a fix for a client that hangs on disconnect when a redirected USB device has a transfer pending;
- pull request #13618 (already in FreeRDP master, newer than the base of #13608): no real USB device reset,
  cancelled transfers complete normally. Some USB devices (e.g. tachograph download keys) stall without it.

Each change is a separate commit with its description. When they reach a FreeRDP release, the image goes back
to Debian's packages.

The packages are built by `image/freerdp/build-debs.sh` (Debian's trixie-backports packaging, with
`-DWITH_RDPEUDP=ON`). The image build downloads the prebuilt ones from the release named in `freerdp.conf`
and checks them against `image/freerdp/SHA256SUMS`, or builds them when that file is missing. To use Debian's
FreeRDP instead (TCP only), set `FREERDP_FROM=backports` in `build.conf`.

## Reporting

Problems with UDP itself (a session that freezes, drops, falls back to TCP) are worth reporting upstream,
in the pull request thread, with:

- the FreeRDP log of the session (`/tmp/kiosk.log` on the device, or `events.log` in the management folder);
- what the network was doing (Wi-Fi, VPN, loss), and the Windows version of the session host.

Problems with the kiosk or the image: issues in this repository.
