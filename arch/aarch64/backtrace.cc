/*
 * Copyright (C) 2014 Huawei Technologies Duesseldorf GmbH
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include "safe-ptr.hh"
#include "exceptions.hh"
#include <osv/debug.h>

struct frame {
    frame* next;
    void* pc;
};

static inline int unwind_fp_chain(frame* fp, void** pc, int nr, int i)
{
    frame* next;

    while (i < nr
           && fp
           && safe_load(&fp->next, next)
           && safe_load(&fp->pc, pc[i])) {
        fp = next;
        ++i;
    }

    return i;
}

int backtrace_safe(void** pc, int nr)
{
    frame* fp;

    asm ("mov %0, x29" : "=r"(fp));
    return unwind_fp_chain(fp, pc, nr, 0);
}

int backtrace_safe_from_interrupt(void** pc, int nr)
{
    // See the x64 implementation for the rationale.  x29 is the frame pointer
    // and elr holds the interrupted pc.
    exception_frame* ef = current_interrupt_frame;
    if (!ef) {
        return backtrace_safe(pc, nr);
    }
    if (nr < 1) {
        return 0;
    }
    pc[0] = (void*)ef->elr;
    return unwind_fp_chain((frame*)ef->regs[29], pc, nr, 1);
}
