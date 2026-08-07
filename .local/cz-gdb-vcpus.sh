#!/usr/bin/env bash
set -u
cd /scratch/gburd/osv-build

cat > /scratch/gburd/cz-gdb-vcpus.cmds << 'CMDS'
set pagination off
osv syms
echo \n===== NATIVE vCPU threads =====\n
info threads
echo \n--- gdb thread 1 live bt ---\n
thread 1
info registers rsp rbp rip
bt -30
echo \n--- gdb thread 2 live bt ---\n
thread 2
info registers rsp rbp rip
bt -30
echo \n===== mutex 0x600000e8ed28 fields =====\n
p *(lockfree::mutex*)0x600000e8ed28
echo \n===DONE===\n
CMDS

gdb -nx -batch -iex "set auto-load safe-path /" \
  -ex "target remote :1234" -x /scratch/gburd/cz-gdb-vcpus.cmds \
  /scratch/gburd/osv-build/build/release.x64/loader.elf \
  2>/dev/null | sed -n '/NATIVE vCPU threads/,$p'
echo GDB_VCPUS_DONE
