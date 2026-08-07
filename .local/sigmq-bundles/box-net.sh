#!/bin/bash
# Set up br0 + tap0 for OSv guest at 192.168.100.2. For MQ (JOB E) pass QUEUES=N.
set -u
BR=br0; TAP=tap0; BR_IP=192.168.100.1; GUEST_IP=192.168.100.2
QUEUES="${1:-0}"   # 0 = single-queue tap; N>0 = multiqueue tap
# tear down existing tap so we can recreate with the right queue count
sudo ip link del "$TAP" 2>/dev/null || true
if ! ip link show "$BR" >/dev/null 2>&1; then
  sudo ip link add name "$BR" type bridge
  sudo ip addr add "$BR_IP/24" dev "$BR"
fi
sudo ip link set "$BR" up
if [ "$QUEUES" -gt 0 ]; then
  sudo ip tuntap add dev "$TAP" mode tap user root multi_queue
else
  sudo ip tuntap add dev "$TAP" mode tap user root
fi
sudo ip link set "$TAP" master "$BR"
sudo ip link set "$TAP" up
echo "br0 up host=$BR_IP guest=$GUEST_IP tap=$TAP queues=$QUEUES"
