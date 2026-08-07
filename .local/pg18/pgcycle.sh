#!/bin/bash
# rebuild postgres (if changed), repackage ramfs image, kill stale qemu, boot PG, dump console.
# usage: pgcycle.sh [rebuild-pg]
set -e
cd /b/.local/pg18/obj
if [ "$1" = "rebuild-pg" ]; then
  make -j"$(nproc)" LDFLAGS_EX='-pie' -C src/backend >/tmp/pgmake.log 2>&1 || { tail -20 /tmp/pgmake.log; exit 1; }
  cp /b/.local/pg18/obj/src/backend/postgres /b/.local/pg18/install/bin/postgres
fi
cd /b/.local/worktrees/fork-arena
scripts/build -j"$(nproc)" fs=ramfs image=pg18-fork >/tmp/osvbuild.log 2>&1 || { tail -10 /tmp/osvbuild.log; exit 1; }
