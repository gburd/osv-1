#!/usr/bin/env bash
cd /scratch/gburd/osv-build
UUID=2321c7c3-8084-41f3-a6de-fa368d51e3b6
nix-shell -p boost ncurses --run "
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
    --crucible0=192.168.122.1:3811,192.168.122.1:3812,192.168.122.1:3813 \
    --crucible0-uuid=$UUID \
    --crucible-block-size=4096 \
    -e \"tests/tst-crucible-zfs.so\"
" 2>&1
echo "===RUN_DONE rc=$?==="
