#!/bin/bash
set -e
cd /b
g++ -std=c++11 -g -O2 -fPIC -shared -D__OSV__ -o build/release.x64/zfs-bench.so zfs_bench.cc
g++ -std=c++11 -g -O2 -fPIC -shared -D__OSV__ -o build/release.x64/zfs-featd.so zfs_featd.cc
cd build/release.x64
# ensure manifest still lists benches (skel-based regen keeps it)
grep -q zfs-bench zfs_builder_bootfs.manifest || echo "/zfs-bench.so: zfs-bench.so" >> zfs_builder_bootfs.manifest
grep -q zfs-featd zfs_builder_bootfs.manifest || echo "/zfs-featd.so: zfs-featd.so" >> zfs_builder_bootfs.manifest
GCCDIR=$(dirname $(gcc -print-file-name=libgcc_s.so.1))
/b/scripts/mkbootfs.py -o zfs_builder_bootfs.bin -d zfs_builder_bootfs.bin.d -m zfs_builder_bootfs.manifest -D libgcc_s_dir=$GCCDIR >/dev/null 2>&1
cd /b
rm -f build/release.x64/zfs_builder_bootfs.o build/release.x64/zfs_builder.elf
make conf_zfs=openzfs OSV_NO_JAVA_TESTS=1 -j$(nproc) build/release.x64/zfs_builder.elf 2>&1 | tail -2
echo REBUILT
