# UDP bench: reproduce the lossy-line numbers

The numbers in [docs/udp.md](../../docs/udp.md#on-a-lossy-line) come from these scripts. Run them on your network
and servers and post what you get in the
[discussions](https://github.com/OpenThinRdp/openthinrdp/discussions): numbers from other environments are what
make them worth something.

## What you need

- A thin client with OpenThinRDP (or any Debian 13 with FreeRDP built with `-DWITH_RDPEUDP=ON`), as root, with
  `xvfb` (`apt install xvfb`) and the `ifb` kernel module (Debian's kernel has it).
- A Windows 10/11 or Server session you can sign in to, over a broker or directly, with the RemoteFX counters
  (any Windows with Remote Desktop has them), and PowerShell remoting to it for the counters (or run
  `counters.ps1` in it).

The test session runs on an invisible screen (Xvfb), so it does not disturb the kiosk; use a test user, because
the kiosk and the test cannot share a Windows session. Loss is applied **only to the traffic coming from the
session host**, on the client, with `tc`/netem through an `ifb` device.

## Steps

```sh
# 1. on the thin client, as root
export RDP_HOST=rdbroker.example.com RDP_USER=test RDP_DOMAIN=EXAMPLE RDP_PASSWORD='...'
export RDP_EXTRA='/load-balance-info:tsv://VMResource.1.EXAMPLE_VDI'   # only behind a VDI broker
export VM_IP=192.0.2.20                                                # the session host the broker redirects to
./session.sh start bench                      # UDP; add -multitransport to RDP_EXTRA for a TCP-only run
```

```powershell
# 2. in the Windows session of the test user (or a scheduled task "at logon" for that user): the load
powershell -ExecutionPolicy Bypass -File load.ps1 -Seconds 900
```

```sh
# 3. back on the thin client: the line, then the steps (seconds per step, then the loss of each step in %)
./line.sh faulty-port        # 43% of the packets >= 512 bytes and 5% of the smaller ones, as our faulty port
./ramp.sh 120 50 70 80       # loss on EVERY packet from VM_IP, step by step, until the session gives up
cat ramp.log
./line.sh off; ./session.sh stop bench
```

```powershell
# 4. while it runs, the frame rate and loss the server sees, every 10 s
.\counters.ps1 -ComputerName <session host> -Samples 60 -Interval 10
```

## What we measure

The server's own counters (RemoteFX Graphics: output frames per second, frames skipped for insufficient network
resources; RemoteFX Network: UDP bandwidth, loss and retransmission rate), not the client's: they say what the
user sees and what the server had to resend. The client log (`/tmp/bench-<name>.log`) says why a session ended.
