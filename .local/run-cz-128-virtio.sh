#!/usr/bin/env bash
# Control: same tst-crucible-zfs workload but on a plain virtio scratch disk
# (/dev/vblk1) instead of /dev/crucible0.  Isolates whether the 16 MiB OOM at
# 128 MiB RAM is Crucible-specific or a generic untuned-ZFS-at-low-RAM property.
set -uo pipefail
cd /scratch/gburd/osv-build
SCRATCH=/scratch/gburd/cz-vblk-scratch.raw
# 1 GiB scratch disk for the pool
rm -f "$SCRATCH"
nix-shell -p qemu --run "qemu-img create -f raw $SCRATCH 1G" >/dev/null 2>&1
timeout 360 nix-shell -p boost ncurses --run "
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 128 -c1 --novnc \
    --second-disk-image $SCRATCH \
    -e '--env=CRUCIBLE_ZFS_DEV=/dev/vblk1 tests/tst-crucible-zfs.so'
" > /scratch/gburd/cz-128-vblk.log 2>&1
echo "EXIT=$?" >> /scratch/gburd/cz-128-vblk.log
