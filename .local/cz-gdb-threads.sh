#!/usr/bin/env bash
set -u
cd /scratch/gburd/osv-build

cat > /scratch/gburd/cz-gdb-threads.cmds << 'CMDS'
set pagination off
osv syms
python
import gdb
# Use loader.py helpers to walk OSv green threads and print status + top frames.
state = vmstate()
def topframes(th, n=14):
    try:
        rbp = int(th['_state']['rbp'])
        rip = int(th['_state']['rip'])
    except Exception as e:
        return "  <no state: %s>" % e
    lines=[]
    import gdb
    for i in range(n):
        if rbp==0 or rip==0: break
        try:
            sym = gdb.execute("info symbol 0x%x" % rip, to_string=True).strip().split(' in section')[0]
        except Exception:
            sym = "0x%x" % rip
        lines.append("    #%-2d 0x%x  %s" % (i, rip, sym))
        try:
            nextrbp = int(gdb.Value(rbp).cast(gdb.lookup_type('unsigned long').pointer()).dereference())
            nextrip = int(gdb.Value(rbp+8).cast(gdb.lookup_type('unsigned long').pointer()).dereference())
        except Exception:
            break
        if nextrbp <= rbp: break
        rbp, rip = nextrbp, nextrip
    return "\n".join(lines)

want_names = ("tst-cruci","crucible","io_loop","z_wr","z_rd","z_null","txg","spa","zio","dp_sync","metaslab","solthread")
for th in state.thread_list:
    try:
        tid=int(th['_id'])
        name=th['_attr']['_name']['_M_elems'].string().strip('\x00')
    except Exception:
        continue
    # status
    try:
        st = unique_ptr_get(th['_detached_state'])['st']['_M_i']
        sts = str(st)
    except Exception as e:
        sts = "?%s"%e
    keep = any(w in name for w in want_names)
    if keep:
        print("=== tid %d  %-20s  status=%s ===" % (tid, name, sts))
        print(topframes(th))
end
echo \n===DONE===\n
CMDS

gdb -nx -batch -iex "set auto-load safe-path /" \
  -ex "target remote :1234" -x /scratch/gburd/cz-gdb-threads.cmds \
  /scratch/gburd/osv-build/build/release.x64/loader.elf \
  2>/dev/null | sed -n '/=== tid/,$p'
echo GDB_THREADS_DONE
