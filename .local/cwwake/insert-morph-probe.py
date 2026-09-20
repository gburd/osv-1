#!/usr/bin/env python3
# Morph/wake-path probe v2 - matches the box's actual wake_impl (prefer_local param).
# Global counters in thread::wake_impl classify every wake:
#   mp_wake_calls, mp_null_st (st==NULL early return), mp_cas_lost (not in allowed state),
#   mp_same_cpu, mp_xcpu, mp_mask_already (xcpu wake, mask bit already set -> no ipi/no resched),
#   mp_ipi_path, mp_retarget (WAKE_LOCAL retarget).
# osv_morph_dump() extern "C" default-visibility for the zil watchdog to call.
import sys
F = "/work/osv/core/sched.cc"
s = open(F).read()
if "osv_morph_dump" in s:
    print("MORPH PROBE ALREADY PRESENT"); sys.exit(0)

# 1) counters + dump before the 2-line wake_impl signature
anchor_wi = ("void thread::wake_impl(detached_state* st, unsigned allowed_initial_states_mask,\n"
             "                       bool prefer_local)\n{")
block = ('''// OSv cross-vCPU wake-path probe (localizes the ZIL completion->waiter lost
// wake). Relaxed global counters; dumped by the ZIL watchdog via osv_morph_dump.
static volatile unsigned long mp_wake_calls;
static volatile unsigned long mp_null_st;
static volatile unsigned long mp_cas_lost;        // thread not in allowed state -> wake DROPPED
static volatile unsigned long mp_same_cpu;
static volatile unsigned long mp_xcpu;
static volatile unsigned long mp_mask_already;    // xcpu wake, mask bit ALREADY set -> no ipi, no resched
static volatile unsigned long mp_ipi_path;
extern "C" __attribute__((visibility("default"))) void osv_morph_dump(void);
extern "C" __attribute__((visibility("default"))) void osv_morph_dump(void)
{
    printf("RESULT MORPH wake_calls=%lu null_st=%lu cas_lost=%lu same_cpu=%lu "
        "xcpu=%lu mask_already=%lu ipi_path=%lu\\n",
        mp_wake_calls, mp_null_st, mp_cas_lost, mp_same_cpu, mp_xcpu,
        mp_mask_already, mp_ipi_path);
}

void thread::wake_impl(detached_state* st, unsigned allowed_initial_states_mask,
                       bool prefer_local)
{''')
assert s.count(anchor_wi) == 1, "wake_impl anchor %d" % s.count(anchor_wi)
s = s.replace(anchor_wi, block, 1)

# 2) null_st + CAS-lost counters
anchor_cas = ('''    if (!st) {
        return;
    }
    status old_status = status::waiting;
    trace_sched_wake(st->t);
    while (!st->st.compare_exchange_weak(old_status, status::waking)) {
        if (!((1 << unsigned(old_status)) & allowed_initial_states_mask)) {
            return;
        }
    }''')
repl_cas = ('''    if (!st) {
        __atomic_add_fetch(&mp_null_st, 1, __ATOMIC_RELAXED);
        return;
    }
    status old_status = status::waiting;
    trace_sched_wake(st->t);
    __atomic_add_fetch(&mp_wake_calls, 1, __ATOMIC_RELAXED);
    while (!st->st.compare_exchange_weak(old_status, status::waking)) {
        if (!((1 << unsigned(old_status)) & allowed_initial_states_mask)) {
            __atomic_add_fetch(&mp_cas_lost, 1, __ATOMIC_RELAXED);
            return;
        }
    }''')
assert s.count(anchor_cas) == 1, "cas anchor %d" % s.count(anchor_cas)
s = s.replace(anchor_cas, repl_cas, 1)

# 3) classify enqueue/ipi path
anchor_ipi = ('''        irq_save_lock_type irq_lock;
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
            }''')
repl_ipi = ('''        irq_save_lock_type irq_lock;
        WITH_LOCK(irq_lock) {
            tcpu->incoming_wakeups[c].push_back(*st->t);
        }
        bool xcpu_probe = (tcpu != current()->tcpu());
        if (xcpu_probe) __atomic_add_fetch(&mp_xcpu, 1, __ATOMIC_RELAXED);
        else __atomic_add_fetch(&mp_same_cpu, 1, __ATOMIC_RELAXED);
        if (!tcpu->incoming_wakeups_mask.test_all_and_set(c)) {
            // FIXME: avoid if the cpu is alive and if the priority does not
            // FIXME: warrant an interruption
            if (tcpu != current()->tcpu()) {
                if (xcpu_probe) __atomic_add_fetch(&mp_ipi_path, 1, __ATOMIC_RELAXED);
                tcpu->send_wakeup_ipi();
            } else {
                need_reschedule = true;
            }
        } else if (xcpu_probe) {
            // mask bit already set for source c: NO ipi, need_reschedule NOT set.
            // If the target then halts, this cross-cpu wake can be lost.
            __atomic_add_fetch(&mp_mask_already, 1, __ATOMIC_RELAXED);''')
assert s.count(anchor_ipi) == 1, "ipi anchor %d" % s.count(anchor_ipi)
s = s.replace(anchor_ipi, repl_ipi, 1)

open(F, "w").write(s)
print("MORPH PROBE v2 APPLIED OK")
