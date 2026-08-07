#!/bin/bash
# 00-net-bridge.sh -- DB HOST. Build the REAL NIC path for the guest:
#   Linux bridge br0 + tap0 (vhost=on in qemu) + DNAT host-ENI:5432 -> guest:5432.
# Replaces qemu user-net (slirp) which wedges under concurrent load.
#
#   driver EC2 --(intra-SG)--> 172.31.5.69:5432 (host ENI ens5)
#      --iptables DNAT-->      192.168.100.2:5432 (guest on br0/tap0)
#
# The guest sees a first-class virtio-net NIC on tap0 (bridged), NOT slirp.
# Idempotent. Run once per boot of the DB host (or after a reboot).
set -eu
HOST_ENI=ens5
HOST_IP=172.31.5.69
BR=br0
TAP=tap0
BR_IP=192.168.100.1
GUEST_IP=192.168.100.2
PGPORT=5432
USER_OWN="${SUDO_USER:-$(whoami)}"

# 1) bridge br0 (idempotent)
if ! ip link show "$BR" >/dev/null 2>&1; then
  sudo ip link add name "$BR" type bridge
  sudo ip addr add "$BR_IP/24" dev "$BR"
fi
sudo ip link set "$BR" up

# 2) tap0 owned by the qemu-running user, enslaved to br0 (idempotent)
if ! ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip tuntap add dev "$TAP" mode tap user "$USER_OWN"
  sudo ip link set "$TAP" master "$BR"
fi
sudo ip link set "$TAP" up

# 3) host IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 4) DNAT host-ENI:5432 -> guest, MASQUERADE guest egress, allow forwarding.
#    Delete-then-add for idempotency.
sudo iptables -t nat -D PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT" 2>/dev/null || true
sudo iptables -t nat -A PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT"
# also DNAT traffic that arrives at the host's own IP locally (so host psql to 172.31.5.69 works too)
sudo iptables -t nat -D OUTPUT -d "$HOST_IP" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT" 2>/dev/null || true
sudo iptables -t nat -A OUTPUT -d "$HOST_IP" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT"
sudo iptables -t nat -D POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE
sudo iptables -D FORWARD -o "$BR" -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -o "$BR" -j ACCEPT
sudo iptables -D FORWARD -i "$BR" -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i "$BR" -j ACCEPT

echo "br0 up: host=$BR_IP guest=$GUEST_IP ; tap0 enslaved(vhost) ; DNAT $HOST_IP:$PGPORT -> $GUEST_IP:$PGPORT"
ip -4 addr show "$BR" | grep inet
ip link show "$TAP"
