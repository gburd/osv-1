#!/usr/bin/env bash
set -u
cd /scratch/gburd/osv-build

cat > /scratch/gburd/cz-gdb-ioloop.cmds << 'CMDS'
set pagination off
osv syms
python
import gdb
ulptr = gdb.lookup_type('unsigned long').pointer()
def topframes(th, n=16):
    try:
        rbp = int(th['_state']['rbp']); rip = int(th['_state']['rip'])
    except Exception as e:
        return ["  <no state %s>"%e]
    out=[]
    for i in range(n):
        if not rbp or not rip: break
        try:
            sym = gdb.execute("info symbol 0x%x"%rip, to_string=True).strip().split(' in section')[0]
        except Exception:
            sym="0x%x"%rip
        out.append("    #%-2d 0x%x %s"%(i,rip,sym))
        try:
            nb=int(gdb.Value(rbp).cast(ulptr).dereference())
            nr=int(gdb.Value(rbp+8).cast(ulptr).dereference())
        except Exception: break
        if nb<=rbp: break
        rbp,rip=nb,nr
    return out
state=vmstate()
KEYS=("io_loop","select","crucible","Upstairs","process_responses","poll","epoll","recv","Connection","wait_for")
for th in state.thread_list:
    try:
        tid=int(th['_id']); name=th['_attr']['_name']['_M_elems'].string().strip('\x00')
    except Exception: continue
    frames=topframes(th)
    joined="\n".join(frames)
    if any(k in joined for k in KEYS):
        try:
            st=unique_ptr_get(th['_detached_state'])['st']['_M_i']; sts=str(st)
        except Exception as e: sts="?%s"%e
        print("=== tid %d %-18s status=%s ==="%(tid,name,sts))
        print(joined)
end
echo \n===DONE===\n
CMDS

gdb -nx -batch -iex "set auto-load safe-path /" \
  -ex "target remote :1234" -x /scratch/gburd/cz-gdb-ioloop.cmds \
  /scratch/gburd/osv-build/build/release.x64/loader.elf \
  2>/dev/null | sed -n '/=== tid/,$p'
echo GDB_IOLOOP_DONE
