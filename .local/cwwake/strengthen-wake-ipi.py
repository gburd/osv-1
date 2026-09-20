#!/usr/bin/env python3
# Strengthen the wake A/B: OSV_WAKE_IPI_ALWAYS=1 now (a) ignores idle_poll too
# (truly unconditional IPI) and (b) bypasses the incoming_wakeups_mask
# test_all_and_set guard in wake_impl so EVERY cross-cpu wake sends an IPI.
# This closes the last send-side gaps (idle_poll-suppression + mask-already
# suppression). If it STILL wedges, the lost wake is NOT on the IPI-delivery
# side at all. Idempotent.
import sys
F = "/work/osv/core/sched.cc"
s = open(F).read()
if "WAKE_IPI_ALWAYS_v2" in s:
    print("v2 ALREADY PRESENT"); sys.exit(0)

# (a) make send_wakeup_ipi truly unconditional when always
old_send = '''    if (always) {
        if (!idle_poll.load(std::memory_order_relaxed)) {
            trace_sched_ipi(id);
            wakeup_ipi.send(this);
        }
        return;
    }'''
new_send = '''    if (always) { /* WAKE_IPI_ALWAYS_v2: truly unconditional */
        trace_sched_ipi(id);
        wakeup_ipi.send(this);
        return;
    }'''
assert s.count(old_send) == 1, "send anchor %d" % s.count(old_send)
s = s.replace(old_send, new_send, 1)

# (b) bypass the test_all_and_set guard in wake_impl for cross-cpu when always.
# Match the box's elaborate wake_impl enqueue block.
old_wi = '''        irq_save_lock_type irq_lock;
        WITH_LOCK(irq_lock) {
            tcpu->incoming_wakeups[c].push_back(*st->t);
        }
        if (!tcpu->incoming_wakeups_mask.test_all_and_set(c)) {
            // FIXME: avoid if the cpu is alive and if the priority does not
            // FIXME: warrant an interruption
            if (tcpu != current()->tcpu()) {
                tcpu->send_wakeup_ipi();
            } else {
                need_reschedule = true;
            }
        }'''
new_wi = '''        irq_save_lock_type irq_lock;
        WITH_LOCK(irq_lock) {
            tcpu->incoming_wakeups[c].push_back(*st->t);
        }
        static int wake_force = [] {
            const char* e = getenv("OSV_WAKE_IPI_ALWAYS");
            return (e && e[0] && e[0] != '0') ? 1 : 0;
        }();
        bool newly_set = !tcpu->incoming_wakeups_mask.test_all_and_set(c);
        if (newly_set || wake_force) {
            // FIXME: avoid if the cpu is alive and if the priority does not
            // FIXME: warrant an interruption
            if (tcpu != current()->tcpu()) {
                tcpu->send_wakeup_ipi();
            } else {
                need_reschedule = true;
            }
        }'''
assert s.count(old_wi) == 1, "wi anchor %d" % s.count(old_wi)
s = s.replace(old_wi, new_wi, 1)

open(F, "w").write(s)
print("WAKE_IPI_ALWAYS_v2 APPLIED OK")
