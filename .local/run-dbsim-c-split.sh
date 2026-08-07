#!/usr/bin/env bash
# Config (c): db-sim over ZFS, bulk data on Crucible + ZIL/WAL on NVMe-oF SLOG.
set -uo pipefail
cd /scratch/gburd/osv-build

UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
CRUC="192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813"
NVMEOF="192.168.122.1:4420"
SUBNQN="nqn.2026-06.org.osv:target0"

echo "=== config (c) split: Crucible data + NVMe-oF SLOG @128MiB ==="
echo "downstairs:"
pgrep -af "crucible-downstairs run" | grep -oE "port 381[0-9]" | sort

timeout 240 ./scripts/run.py -k --arch=x86_64 --vnc none -m 128 -c1 \
    -e "--crucible0=$CRUC --crucible0-uuid=$UUID --crucible-block-size=4096 --nvmeof0=$NVMEOF --nvmeof0-subnqn=$SUBNQN --env=DBSIM_DATA_DEV=/dev/crucible0 --env=DBSIM_LOG_DEV=/dev/nvmeof0 --env=DBSIM_DB_MB=256 --env=DBSIM_SECONDS=30 tests/tst-zfs-dbsim-dev.so" \
    2>&1 | tee /scratch/gburd/dbsim-c-split.log | tail -60
echo "=== exit: $? ==="
