#!/usr/bin/env python3
# Add mask-bypass to the morph-probe wake_impl block: when OSV_WAKE_IPI_ALWAYS,
# even the mask-already path sends the IPI (closes the last suppression).
import sys
F = "/work/osv/core/sched.cc"
s = open(F).read()
if "wake_force_mask" in s:
    print("MASK BYPASS ALREADY PRESENT"); sys.exit(0)

old = '''        } else if (xcpu_probe) {
            // mask bit already set for source c: NO ipi, need_reschedule NOT set.
            // If the target then halts, this cross-cpu wake can be lost.
            __atomic_add_fetch(&mp_mask_already, 1, __ATOMIC_RELAXED);'''
new = '''        } else if (xcpu_probe) {
            // mask bit already set for source c: NO ipi, need_reschedule NOT set.
            // If the target then halts, this cross-cpu wake can be lost.
            __atomic_add_fetch(&mp_mask_already, 1, __ATOMIC_RELAXED);
            static int wake_force_mask = [] {
                const char* e = getenv("OSV_WAKE_IPI_ALWAYS");
                return (e && e[0] && e[0] != '0') ? 1 : 0;
            }();
            if (wake_force_mask)
                tcpu->send_wakeup_ipi();'''
assert s.count(old) == 1, "anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("MASK BYPASS APPLIED OK")
