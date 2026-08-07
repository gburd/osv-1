#!/usr/bin/env bash
# Config (a): db-sim over ZFS on a single NVMe-oF/TCP target (single-copy).
set -uo pipefail
cd /scratch/gburd/osv-build

NVMEOF="192.168.122.1:4420"
SUBNQN="nqn.2026-06.org.osv:target0"

echo "=== config (a) NVMe-oF-only @128MiB ==="
timeout 240 ./scripts/run.py -k --arch=x86_64 --vnc none -m 128 -c1 \
    -e "--nvmeof0=$NVMEOF --nvmeof0-subnqn=$SUBNQN --env=DBSIM_DATA_DEV=/dev/nvmeof0 --env=DBSIM_DB_MB=256 --env=DBSIM_SECONDS=30 tests/tst-zfs-dbsim-dev.so" \
    2>&1 | tee /scratch/gburd/dbsim-a-nvmeof.log | tail -60
echo "=== exit: $? ==="
