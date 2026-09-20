#!/usr/bin/env python3
# Apply OSV_WAKE_IPI_ALWAYS env gate to core/sched.cc send_wakeup_ipi. Idempotent.
import sys
F = "/work/osv/core/sched.cc"
s = open(F).read()
if "OSV_WAKE_IPI_ALWAYS" in s:
    print("WAKE_IPI_ALWAYS ALREADY PRESENT"); sys.exit(0)

old = ('''void cpu::send_wakeup_ipi()
{
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (!idle_poll.load(std::memory_order_relaxed) && runqueue.size() <= 1) {
        trace_sched_ipi(id);
        wakeup_ipi.send(this);
    }
}''')
new = ('''void cpu::send_wakeup_ipi()
{
    std::atomic_thread_fence(std::memory_order_seq_cst);
    // OSv cross-vCPU wake correctness A/B (OSV_WAKE_IPI_ALWAYS=1, default off):
    // the stock guard suppresses the wake IPI when runqueue.size() > 1, on the
    // assumption a target carrying queued work reschedules on its own.  That is
    // FALSE for a target that has queued threads but is HALTED in
    // wait_for_interrupt() (nothing pokes a halted CPU), so a cross-vCPU wake
    // enqueued to its incoming_wakeups can sit UNSEEN -> lost wakeup.  With
    // this env set we suppress the IPI only when the target is genuinely
    // idle-polling and otherwise ALWAYS send.  Resolved once, cached.
    static int always = [] {
        const char* e = getenv("OSV_WAKE_IPI_ALWAYS");
        return (e && e[0] && e[0] != '0') ? 1 : 0;
    }();
    if (always) {
        if (!idle_poll.load(std::memory_order_relaxed)) {
            trace_sched_ipi(id);
            wakeup_ipi.send(this);
        }
        return;
    }
    if (!idle_poll.load(std::memory_order_relaxed) && runqueue.size() <= 1) {
        trace_sched_ipi(id);
        wakeup_ipi.send(this);
    }
}''')
assert s.count(old) == 1, "anchor count %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("WAKE_IPI_ALWAYS APPLIED OK")
