#!/usr/bin/env bash
# Multi-host ZFS-on-Crucible run: three downstairs on three physical hosts.
#   target 0: meh-local  via slirp gateway 192.168.122.1:3821
#   target 1: nuc        100.76.219.47:3821   (tailnet, NAT'd out of meh)
#   target 2: arnold     100.117.233.104:3821 (tailnet, NAT'd out of meh)
set -euo pipefail
cd /scratch/gburd/osv-build
UUID=a878bbd3-17ef-40fe-bfc5-7a21ebe9d7de
timeout 240 nix-shell -p boost ncurses --run '
  ./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc \
    --crucible0=192.168.122.1:3821,100.76.219.47:3821,100.117.233.104:3821 \
    --crucible0-uuid='"$UUID"' \
    --crucible-block-size=4096 \
    -e "tests/tst-crucible-zfs.so"
' 2>&1
echo "===RUN_DONE rc=$?==="
