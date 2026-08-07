#!/usr/bin/env bash
# tst-crucible-zfs at 128 MiB RAM: ZFS-on-Crucible, 256 MiB workload sweep
# (working set 2x RAM).  Local-isolated topology: 3 downstairs already running
# on meh ports 3811-3813.
set -uo pipefail
cd /scratch/gburd/osv-build
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
timeout 480 nix-shell -p boost ncurses --run "
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 128 -c1 --novnc \
    --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
    --crucible0-uuid=$UUID \
    --crucible-block-size=4096 \
    -e 'tests/tst-crucible-zfs.so'
" > /scratch/gburd/cz-128-local.log 2>&1
echo "EXIT=$?" >> /scratch/gburd/cz-128-local.log
