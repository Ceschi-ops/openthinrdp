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

## On a lossy line

It started with a switch port with a faulty transceiver, losing **43% of the large packets** (5% of the small
ones). We reproduced it with netem on the thin client, on the traffic from the virtual machine only, then raised
the loss on every packet step by step until the session gave up. Windows 11 VDI behind the broker, full-screen
load that changes every pixel at 30 frames per second; frame rate and loss as reported by the server; 90-120 s per
step.

| packets lost | OpenThinRDP over UDP | TCP, same line and load |
|---|---|---|
| 0% | 15-21 fps | not measured |
| 5% | not measured | 7-12 fps |
| 10% | not measured | 6 fps |
| 20% | not measured | **0.6 fps**, the screen barely moves |
| 30% | not measured | 0.2 fps, 26 frames a second dropped by the server |
| 43% of the large packets only\* (the faulty port) | **16-21 fps**, 7 minutes in a row | 0-0.1 fps |
| 50% | **19-21 fps** | not measured (already at 0.2 fps with 30%) |
| 60% | 14-21 fps | not measured |
| **70%** | **18-19 fps**\*\* | not measured |
| 80% | 4 fps, then the tunnel gives up after 18 s | not measured |

\* Every other row loses that share of all the packets from the virtual machine; this one, as on the faulty port,
43% of the large packets and 5% of the small ones.
\*\* With the FreeRDP of OpenThinRDP 0.1.5 (no 1 s freeze at every wrap of the channel sequence; 9-13 fps
before). At 70% the first thing to give up is the TCP connection that RDP keeps beside the UDP tunnel: after
20 s without an acknowledgement (`/timeout`, set by the kiosk) it ends the session, which happened once after
100 s and not in another run of 150 s.

On UDP no frame was dropped by the server for network reasons up to 70%. A session opened when the line is
already bad is set up over UDP too (14-19 fps at 43%).

**Limits of these numbers:** one environment (Dell OptiPlex 3000 Thin Client, Windows 11 VDI on Hyper-V behind an
RD Connection Broker), one kind of load, loss emulated with netem on the client. The method and the scripts are
in [tests/udp-bench](../tests/udp-bench/README.md): numbers from other networks and servers are very welcome.

Over TCP every lost packet holds up everything behind it until it is resent; over UDP the lost packets are resent
while the rest of the stream goes on. Getting there took a fix to the UDP transport: after the channel sequence
wrapped, an unsigned difference went below zero, the client believed the stream had been stuck for ages and
ended the connection within 1-25 seconds of the loss starting. We reported it with a fix in the pull request; its
author fixed the root cause there (the client now skips channel sequence 0 like Windows does).

## The FreeRDP in the image

`image/freerdp/freerdp.conf` names the exact source: branch
[`openthinrdp-udp-3.32.2`](https://github.com/Ceschi-ops/FreeRDP/tree/openthinrdp-udp-3.32.2) of a FreeRDP fork, which is
the **FreeRDP 3.32.2** release (the security release of 2026-10-12) with the commits of pull request #13608, the UDP
transport, applied unchanged, and two commits of ours: no false "stream is stuck" after a delivery in `run_timers`
(see above), and ten SYN attempts instead of four (SYN and SYN+ACK are padded to the MTU, the first packets a bad
line loses).

FreeRDP 3.32.2 already contains the USB fixes found while building OpenThinRDP: #13674 (deadlock between USB hotplug
and the closing of the USB channel) and #13679 (from our #13677: no hang on disconnect with a USB transfer pending),
plus #13618 (no real USB device reset). When the UDP transport reaches a FreeRDP release, the image goes back to
Debian's packages.

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
