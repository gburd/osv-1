#!/usr/bin/env python3
# Fix the OSV_CONDVAR_NO_MORPH waiter side: a directly-woken waiter (no morph)
# did NOT receive the user_mutex via send_lock, so it must take the real lock(),
# not receive_lock() (which only stamps ownership -> double-owner assert).
import sys
F = "/work/osv/core/condvar.cc"
s = open(F).read()
if "condvar_no_morph() ? " in s or "no_morph re-lock" in s:
    print("WAIT FIX ALREADY PRESENT"); sys.exit(0)

# forward-declare condvar_no_morph() before condvar::wait uses it
fwd = "TRACEPOINT(trace_condvar_wake_all, \"%p\", condvar *);\n"
if "static bool condvar_no_morph();" not in s:
    s = s.replace(fwd, fwd + "static bool condvar_no_morph();\n", 1)

old = '''    if (wr.woken()) {
        // Our wr was woken. The "wait morphing" protocol used by
        // condvar_wake*() ensures that this only happens after we got the
        // user_mutex for ourselves, so no need to mutex_lock() here.
        user_mutex->receive_lock();
    } else {
        user_mutex->lock();
    }'''
new = '''    if (wr.woken() && !condvar_no_morph()) {
        // Our wr was woken. The "wait morphing" protocol used by
        // condvar_wake*() ensures that this only happens after we got the
        // user_mutex for ourselves, so no need to mutex_lock() here.
        user_mutex->receive_lock();
    } else {
        // no_morph re-lock: a directly-woken waiter did not receive the mutex
        // via send_lock(), so it must contend for it normally.
        user_mutex->lock();
    }'''
assert s.count(old) == 1, "wait tail anchor %d" % s.count(old)
s = s.replace(old, new, 1)
open(F, "w").write(s)
print("WAIT FIX APPLIED OK")
