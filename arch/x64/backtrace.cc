/*
 * Copyright (C) 2013 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include "safe-ptr.hh"
#include "exceptions.hh"

#include <osv/execinfo.hh>

struct frame {
    frame* next;
    void* pc;
};

// Walk a frame-pointer chain, appending return addresses to pc[].
static inline int unwind_fp_chain(frame* rbp, void** pc, int nr, int i)
{
    frame* next;

    while (i < nr
            && rbp
            && safe_load(&rbp->next, next)
            && safe_load(&rbp->pc, pc[i])
            && pc[i]) {
        rbp = next;
        ++i;
    }
    return i;
}

int backtrace_safe(void** pc, int nr)
{
    frame* rbp;

    asm("mov %%rbp, %0" : "=rm"(rbp));
    return unwind_fp_chain(rbp, pc, nr, 0);
}

int backtrace_safe_from_interrupt(void** pc, int nr)
{
    // current_interrupt_frame is set for the duration of interrupt() and is
    // null everywhere else, so this cleanly distinguishes "sampling an
    // interrupted thread" from "tracing my own call path".
    exception_frame* ef = current_interrupt_frame;
    if (!ef) {
        return backtrace_safe(pc, nr);
    }
    if (nr < 1) {
        return 0;
    }
    // The saved rip is the instruction that was executing when the interrupt
    // arrived.  It is the whole point of this function and it needs no
    // unwinding at all, so it is always correct even where the interrupted
    // code was built without frame pointers.
    pc[0] = (void*)ef->rip;
    // Continue up the interrupted thread's own frame-pointer chain.  Starting
    // from the handler's rbp instead (what backtrace_safe() does) yields only
    // the interrupt-entry frames, because the handler's chain is rooted in
    // interrupt_entry_common and never crosses back into the interrupted
    // stack: the entry stub pushes an exception_frame rather than a frame
    // record, so there is no link for an unwinder to follow.
    return unwind_fp_chain((frame*)ef->rbp, pc, nr, 1);
}



