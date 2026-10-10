# UDP transport (experimental)

Windows sends Remote Desktop graphics over UDP when the client supports MS-RDPEMT/RDPEUDP. With UDP the
server adapts frame rate and quality to the line instead of queueing, which helps on busy servers and lossy
networks. FreeRDP does not ship UDP support yet: it is being reviewed upstream
([FreeRDP pull request #13608](https://github.com/FreeRDP/FreeRDP/pull/13608)).

To try it:

1. Build FreeRDP from that branch as Debian packages with `-DWITH_RDPEUDP=ON` and put them in
   `image/site/debs/` with `FREERDP_FROM=site` (or ship them in an update with `make-update.sh -d`).
2. Set `TRANSPORT=udp` on a few devices.

With `TRANSPORT=udp` the kiosk runs FreeRDP with `/network:auto` and **without** `/auto-reconnect`: when the
UDP tunnel fails the client ends the connection and the kiosk opens a new one, which tries UDP again. With
`TRANSPORT=tcp` and a UDP-capable FreeRDP, the kiosk passes `-multitransport` to stay on TCP.

The `status\<hostname>.txt` line `TRANSPORT=udp (in use: udp|tcp)` shows what the session really uses.

Test results and open questions are in the pull request thread. Keep `TRANSPORT=tcp` for production until the
feature is merged.
