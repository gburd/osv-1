#!/usr/bin/env python3
import sys
F = "/work/osv/core/sched.cc"
s = open(F).read()
if "WAKE_IPI_ALWAYS_v2" in s:
    print("v2 send ALREADY PRESENT"); sys.exit(0)
old = '''    if (always) {
        if (!idle_poll.load(std::memory_order_relaxed)) {
            trace_sched_ipi(id);
            wakeup_ipi.send(this);
        }
        return;
    }'''
new = '''    if (always) { /* WAKE_IPI_ALWAYS_v2: truly unconditional */
        trace_sched_ipi(id);
        wakeup_ipi.send(this);
        return;
    }'''
assert s.count(old) == 1, "send anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("v2 send APPLIED OK")
