#!/bin/bash
# Cross-instance networking for the OSv guest's PostgreSQL, run on the EC2 HOST
# (not inside the build container).  tap0 + host NAT so an external instance in
# subnet 172.31.0.0/20 reaches the guest's PG on the host's private IP:5432.
#
#   external EC2 (same subnet) --> 172.31.12.162:5432 (host ENI)
#       --iptables DNAT-->        192.168.100.2:5432   (OSv guest on tap0)
#
# The guest uses virtio-net on tap0 (a real NIC from the guest's view), NOT
# qemu user-net, so it is a first-class L3 endpoint reachable cross-instance.
set -eu
HOST_ENI=enp125s0
HOST_IP=172.31.12.162
TAP=tap0
TAP_HOST_IP=192.168.100.1
GUEST_IP=192.168.100.2
PGPORT=5432

# 1) create the tap (idempotent)
if ! ip link show "$TAP" >/dev/null 2>&1; then
  sudo ip tuntap add dev "$TAP" mode tap user "$(whoami)"
  sudo ip addr add "$TAP_HOST_IP/24" dev "$TAP"
fi
sudo ip link set "$TAP" up

# 2) host IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# 3) NAT: DNAT the host ENI:5432 to the guest, MASQUERADE guest egress, and
#    allow forwarding.  Flush our own chain first (idempotent).
sudo iptables -t nat -D PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT" 2>/dev/null || true
sudo iptables -t nat -A PREROUTING -i "$HOST_ENI" -p tcp --dport "$PGPORT" -j DNAT --to-destination "$GUEST_IP:$PGPORT"
sudo iptables -t nat -D POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE 2>/dev/null || true
sudo iptables -t nat -A POSTROUTING -s "$GUEST_IP/32" -o "$HOST_ENI" -j MASQUERADE
sudo iptables -D FORWARD -i "$HOST_ENI" -o "$TAP" -p tcp --dport "$PGPORT" -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i "$HOST_ENI" -o "$TAP" -p tcp --dport "$PGPORT" -j ACCEPT
sudo iptables -D FORWARD -i "$TAP" -o "$HOST_ENI" -j ACCEPT 2>/dev/null || true
sudo iptables -A FORWARD -i "$TAP" -o "$HOST_ENI" -j ACCEPT

echo "tap0 up: host=$TAP_HOST_IP guest=$GUEST_IP ; DNAT $HOST_IP:$PGPORT -> $GUEST_IP:$PGPORT"
ip -4 addr show "$TAP" | grep inet
