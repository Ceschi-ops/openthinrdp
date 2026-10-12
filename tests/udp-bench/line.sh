#!/bin/bash
# Lossy line on the thin client, ONLY on the traffic from the session host ($VM_IP), through an ifb device.
#   line.sh faulty-port      43% of the IP packets of 512 bytes and more lost (with some reordering), 5% of the
#                            smaller ones: a switch port with a faulty transceiver, as we met it
#   line.sh loss <percent>   that share of EVERY packet from the session host
#   line.sh off
set -e
: "${VM_IP:?set VM_IP to the address of the session host}"
DEV=$(ip -o route get "$VM_IP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
clear(){ tc qdisc del dev "$DEV" ingress 2>/dev/null || true; tc qdisc del dev ifb1 root 2>/dev/null || true; }
setup(){ # $1 = netem of the large packets, $2 = netem of the small ones
  modprobe ifb; ip link add ifb1 type ifb 2>/dev/null || true; ip link set ifb1 up
  clear
  tc qdisc add dev "$DEV" handle ffff: ingress
  tc filter add dev "$DEV" parent ffff: protocol ip u32 match ip src "$VM_IP/32" action mirred egress redirect dev ifb1
  tc qdisc add dev ifb1 root handle 1: prio bands 3 priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
  tc qdisc add dev ifb1 parent 1:1 handle 10: netem $1 limit 100000
  tc qdisc add dev ifb1 parent 1:2 handle 20: netem $2 limit 100000
  # total length of the IP packet (bytes 2-3) below 512: the small ones; everything else: the large ones
  tc filter add dev ifb1 parent 1: protocol ip prio 1 u32 match u16 0x0000 0xfe00 at 2 flowid 1:2
  tc filter add dev ifb1 parent 1: protocol ip prio 2 u32 match u32 0 0 flowid 1:1
}
case "$1" in
  faulty-port) setup "delay 1ms reorder 70% loss 43%" "loss 5%" ;;
  loss) [[ $2 =~ ^[0-9]+$ ]] || { echo "loss <percent>"; exit 1; }; setup "delay 1ms reorder 70% loss $2%" "loss $2%" ;;
  off) clear; echo "line clean"; exit 0 ;;
  *) echo "line.sh faulty-port | loss <percent> | off"; exit 1 ;;
esac
for s in 56 1400; do printf '  ping %4s bytes: ' $s; ping -M do -s $s -c 100 -i 0.02 -W 1 -q "$VM_IP" | grep -oE '[0-9.]+% packet loss'; done
