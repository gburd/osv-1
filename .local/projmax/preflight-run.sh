#!/bin/bash
# Run bench-preflight with THIS run's declared exclusions and stale-base waiver.
# Paths absolute: the script cd's into the tree, so relative log paths break.
# Copyright (C) 2026 Greg Burd
P=/home/gburd/ws/osv/.local/projmax
export BENCH_ALLOW_STALE_BASE=1
export BENCH_SKIP_PRS="1500 1498 1497 1491 1490 1440"
export BENCH_PR_REASONS="1500:lwext4-pin-ext4-unused-by-this-workload 1498:ahci-atapi-native-boots-from-nvme-not-ahci 1497:superseded-base-generates-the-manifest-entry-in-open_zfs-module.py 1491:aarch64-gicv3-only-inert-on-x86_64 1490:aarch64-phys-map-only-inert-on-x86_64 1440:inotify-conflicting-and-pg-does-not-use-inotify"
exec sh /home/gburd/ws/osv/.local/bench-preflight.sh \
  "$P/wt-compose" \
  --build-log "$P/build-osv-final.log" \
  --runtime-proof "$P/console-preflight.txt"
