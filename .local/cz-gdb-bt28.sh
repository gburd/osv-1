#!/usr/bin/env bash
set -u
cd /scratch/gburd/osv-build

cat > /scratch/gburd/cz-gdb-bt28.cmds << 'CMDS'
set pagination off
osv syms
echo \n===== live vCPU registers =====\n
info registers rsp rbp rip
echo \n===== live backtrace (current = virtio-blk/q1 running) =====\n
bt -80
echo \n===== frame-name histogram via backtrace =====\n
python
import gdb
out = gdb.execute("bt -200", to_string=True)
from collections import Counter
c = Counter()
for line in out.splitlines():
    # lines look like "#12 0x... in NAME (...)" or "#12 NAME (...)"
    if ' in ' in line:
        nm = line.split(' in ',1)[1].split('(')[0].strip()
    else:
        parts = line.split(None,1)
        nm = parts[1].split('(')[0].strip() if len(parts)>1 else line
    c[nm]+=1
print("total frames in bt-200: %d" % sum(c.values()))
for nm,n in c.most_common(25):
    print("  %4d  %s" % (n, nm))
end
echo \n===DONE===\n
CMDS

gdb -nx -batch -iex "set auto-load safe-path /" \
  -ex "target remote :1234" -x /scratch/gburd/cz-gdb-bt28.cmds \
  /scratch/gburd/osv-build/build/release.x64/loader.elf \
  2>/dev/null | sed -n '/live vCPU registers/,$p'
echo GDB_BT28_DONE
