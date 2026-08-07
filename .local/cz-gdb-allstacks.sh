#!/usr/bin/env bash
set -u
cd /scratch/gburd/osv-build

cat > /scratch/gburd/cz-gdb-allstacks.cmds << 'CMDS'
set pagination off
osv syms
python
import gdb
ulong_t = gdb.lookup_type('unsigned long')
def ulong(v): return int(v.cast(ulong_t))
state = vmstate()
# live hardware sp per vCPU
cpusp = {}
try:
    for c in values(state.cpu_list):
        cpusp[int(c.id)] = ulong(c.sp)
except Exception as e:
    print("cpu_list err %s" % e)
print("vCPU live sp: %s" % {k: hex(v) for k,v in cpusp.items()})
rows=[]
for th in state.thread_list:
    try:
        tid=int(th['_id'])
        name=th['_attr']['_name']['_M_elems'].string().strip('\x00')
        begin=ulong(th['_attr']['_stack']['begin'])
        size=ulong(th['_attr']['_stack']['size'])
        rsp=ulong(th['_state']['rsp'])
        # if this thread is the one live on a vCPU, prefer hardware sp
        live=''
        for cid,sp in cpusp.items():
            if begin - size <= sp <= begin + size + (1<<20):
                # rough: sp within or just past this stack
                if begin <= sp <= begin+size or (sp < begin and begin - sp < (1<<20)):
                    pass
        used = (begin + size) - rsp if rsp <= begin+size else -(rsp-(begin+size))
        # used relative to top; overflow if rsp < begin
        over = begin - rsp if rsp < begin else 0
        rows.append((used, over, tid, name, begin, size, rsp))
    except Exception:
        pass
rows.sort(reverse=True)
print("%-6s %-22s %10s %10s %8s %s" % ("tid","name","used","stacksz","OVERFLOW","rsp"))
for used,over,tid,name,begin,size,rsp in rows[:30]:
    flag = "  <<<OVERFLOW" if over>0 else ""
    print("%-6d %-22s %10d %10d %8d 0x%x%s" % (tid,name,used,size,over,rsp,flag))
end
echo \n===DONE===\n
CMDS

gdb -nx -batch -iex "set auto-load safe-path /" \
  -ex "target remote :1234" -x /scratch/gburd/cz-gdb-allstacks.cmds \
  /scratch/gburd/osv-build/build/release.x64/loader.elf \
  > /scratch/gburd/cz-gdb-allstacks.txt 2>&1
echo GDB_ALLSTACKS_DONE
cat /scratch/gburd/cz-gdb-allstacks.txt
