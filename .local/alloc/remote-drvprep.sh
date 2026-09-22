#!/bin/bash
# Driver-box prep: toolchains for THREE arms from ONE source.
#   glibc-gcc   -> Linux/glibc arm
#   musl-gcc    -> Linux/musl arm AND the OSv arm (same binary, same flags)
# Also copies in the OSv rofs image generator (a standalone python script; it
# needs no OSv build).
set -e
exec > /tmp/drvprep.log 2>&1
set -x
export DEBIAN_FRONTEND=noninteractive
for i in 1 2 3 4 5; do sudo apt-get update -y && break || sleep 10; done
sudo apt-get install -y build-essential musl-tools musl-dev python3 gdisk fdisk
echo "=== COMPILERS ==="
gcc --version | head -1
musl-gcc --version | head -1
echo "=== BUILD ALL THREE BINARIES FROM ONE SOURCE, SAME FLAGS ==="
# -O2 only.  No -march=native: the arms must not differ by codegen, and the OSv
# and Linux arms run on the same instance type anyway.
FLAGS="-O2 -Wall -pthread"
echo "FLAGS=$FLAGS"
gcc      $FLAGS -o /tmp/bench-glibc /tmp/bench-alloc.c
musl-gcc $FLAGS -o /tmp/bench-musl-linux /tmp/bench-alloc.c
# The OSv arm needs a PIE (OSv runs applications position-independent; see
# apps/postgres18-musl/build.sh's LDFLAGS_EX=-pie deviation note).
musl-gcc $FLAGS -fPIC -pie -o /tmp/bench-musl /tmp/bench-alloc.c
echo "=== WHAT WE ACTUALLY BUILT ==="
for f in /tmp/bench-glibc /tmp/bench-musl-linux /tmp/bench-musl; do
  echo "--- $f"; file $f; ls -l $f
done
echo "=== LINUX ARMS SMOKE TEST (short, just proves they run) ==="
/tmp/bench-glibc      -C -n 50000 -r 1
/tmp/bench-musl-linux -C -n 50000 -r 1
echo DRVPREP_DONE
