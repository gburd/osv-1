#!/usr/bin/env bash
# tst-crucible-zfs full 256 MiB sweep on local Crucible at 512 MiB RAM.
# Confirms the Crucible data path completes the largest working set when RAM
# is sufficient for the untuned pool (isolates the 128 MiB OOM as a tuning,
# not a Crucible, limit).
set -uo pipefail
cd /scratch/gburd/osv-build
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
timeout 480 nix-shell -p boost ncurses --run "
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 512 -c2 --novnc \
    --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
    --crucible0-uuid=$UUID \
    --crucible-block-size=4096 \
    -e 'tests/tst-crucible-zfs.so'
" > /scratch/gburd/cz-512-local.log 2>&1
echo "EXIT=$?" >> /scratch/gburd/cz-512-local.log
