#!/usr/bin/env python3
# OSV_CONDVAR_NO_MORPH A/B: when set, condvar::wake_one/wake_all wake the waiter
# DIRECTLY (wr->wake()) instead of wait-morphing via _user_mutex->send_lock(wr).
# The waiter then re-contends the user mutex normally on wakeup (condvar::wait's
# !woken() path already handles a wr woken without the lock: it takes
# user_mutex->lock()). Splits morph-RHO (fixed by this) vs raw-wake-CAS (still wedges).
# Idempotent.
import sys
F = "/work/osv/core/condvar.cc"
s = open(F).read()
if "OSV_CONDVAR_NO_MORPH" in s:
    print("NO_MORPH ALREADY PRESENT"); sys.exit(0)

# ensure getenv is declared
if "#include <stdlib.h>" not in s:
    s = s.replace("#include <errno.h>\n", "#include <errno.h>\n#include <stdlib.h>\n", 1)

# helper: a cached env check, inserted before wake_one
anchor_h = "void condvar::wake_one()\n{"
helper = r'''// OSv A/B (OSV_CONDVAR_NO_MORPH=1, default off): skip wait-morphing and wake
// the cv waiter directly.  Splits a lost wake in the morph/RHO handoff (fixed
// by direct wake) from a lost wake in the raw thread::wake_impl CAS (still
// lost).  condvar::wait()'s !woken() branch already re-acquires the user mutex
// with a normal lock(), so a directly-woken waiter is correct (it just costs an
// extra mutex contention instead of the morph optimization).
static bool condvar_no_morph()
{
    static int v = -1;
    if (v < 0) {
        const char* e = getenv("OSV_CONDVAR_NO_MORPH");
        v = (e && e[0] && e[0] != '0') ? 1 : 0;
        printf("OSV_CONDVAR_NO_MORPH: condvar wake mode=%s\n",
            v ? "direct-wake (no morph)" : "wait-morphing (default)");
    }
    return v;
}

void condvar::wake_one()
{'''
assert s.count(anchor_h) == 1, "wake_one anchor %d" % s.count(anchor_h)
s = s.replace(anchor_h, helper, 1)

# wake_one: the send_lock(wr) becomes a conditional direct wake.
# Current post-7241aa187 wake_one body:
anchor_w1 = '''        // Rather than wake the waiter here (wr->wake()) and have it wait
        // again for the mutex, we do "wait morphing" - have it continue to
        // sleep until the mutex becomes available.
        _user_mutex->send_lock(wr);'''
repl_w1 = '''        // Rather than wake the waiter here (wr->wake()) and have it wait
        // again for the mutex, we do "wait morphing" - have it continue to
        // sleep until the mutex becomes available.
        if (condvar_no_morph())
            wr->wake();
        else
            _user_mutex->send_lock(wr);'''
assert s.count(anchor_w1) == 1, "wake_one send_lock anchor %d" % s.count(anchor_w1)
s = s.replace(anchor_w1, repl_w1, 1)

# wake_all: the whole send_lock + same-cpu-batch loop -> direct wake all when no-morph.
# Anchor the body from "_waiters_fifo.oldest = _waiters_fifo.newest = nullptr;" through the loop end.
anchor_wa = '''    _waiters_fifo.oldest = _waiters_fifo.newest = nullptr;
    _m.unlock();
    while (wr) {
        auto next_wr = wr->next; // need to save - *wr invalid after wake
        auto cpu_wr = wr->thread()->tcpu();
        user_mutex->send_lock(wr);
        // As an optimization for many threads to wake up on relatively few
        // CPUs, queue all the threads that will likely wake on the same CPU
        // one after another, as same-CPU wakeup is faster.
        wait_record *prevr = nullptr;
        for (auto r = next_wr; r;) {
            auto nextr = r->next;
            if (r->thread()->tcpu() == cpu_wr) {
                user_mutex->send_lock(r);
                if (r == next_wr) {
                    next_wr = nextr;
                } else {
                    prevr->next = nextr;
                }
            } else {
                prevr = r;
            }
            r = nextr;
        }
        wr = next_wr;
    }'''
repl_wa = '''    _waiters_fifo.oldest = _waiters_fifo.newest = nullptr;
    _m.unlock();
    if (condvar_no_morph()) {
        // Direct-wake A/B: wake every waiter without morphing onto user_mutex.
        (void)user_mutex;
        while (wr) {
            auto next_wr = wr->next; // save - *wr invalid after wake
            wr->wake();
            wr = next_wr;
        }
        return;
    }
    while (wr) {
        auto next_wr = wr->next; // need to save - *wr invalid after wake
        auto cpu_wr = wr->thread()->tcpu();
        user_mutex->send_lock(wr);
        // As an optimization for many threads to wake up on relatively few
        // CPUs, queue all the threads that will likely wake on the same CPU
        // one after another, as same-CPU wakeup is faster.
        wait_record *prevr = nullptr;
        for (auto r = next_wr; r;) {
            auto nextr = r->next;
            if (r->thread()->tcpu() == cpu_wr) {
                user_mutex->send_lock(r);
                if (r == next_wr) {
                    next_wr = nextr;
                } else {
                    prevr->next = nextr;
                }
            } else {
                prevr = r;
            }
            r = nextr;
        }
        wr = next_wr;
    }'''
assert s.count(anchor_wa) == 1, "wake_all body anchor %d" % s.count(anchor_wa)
s = s.replace(anchor_wa, repl_wa, 1)

open(F, "w").write(s)
print("NO_MORPH APPLIED OK")
