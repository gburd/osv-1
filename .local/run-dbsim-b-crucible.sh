#!/usr/bin/env bash
# Config (b): db-sim over ZFS on a single Crucible volume (3-way replicated).
set -uo pipefail
cd /scratch/gburd/osv-build

UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
CRUC="192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813"

echo "=== config (b) Crucible-only @128MiB ==="
echo "downstairs:"
pgrep -af "crucible-downstairs run" | grep -oE "port 381[0-9]" | sort

timeout 240 ./scripts/run.py -k --arch=x86_64 --vnc none -m 128 -c1 \
    -e "--crucible0=$CRUC --crucible0-uuid=$UUID --crucible-block-size=4096 --env=DBSIM_DATA_DEV=/dev/crucible0 --env=DBSIM_DB_MB=256 --env=DBSIM_SECONDS=30 tests/tst-zfs-dbsim-dev.so" \
    2>&1 | tee /scratch/gburd/dbsim-b-crucible.log | tail -60
echo "=== exit: $? ==="
