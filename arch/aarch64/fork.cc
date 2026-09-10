/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread() for aarch64 -- mirrors arch/x64/fork.cc.  fork() (fork.cc)
 * passes the caller's return address, stack pointer and callee-saved register
 * context; we copy the parent's user stack, bias the SP into the copy, and start
 * a child thread that restores the caller's callee-saved registers, installs the
 * copied stack, sets x0=0 (fork()'s return value in the child), and returns to
 * fork()'s caller.
 *
 * Restoring the callee-saved registers is required for the same reason as on
 * x86-64: the trampoline branches straight to fork()'s return address, skipping
 * fork()'s epilogue, and the AAPCS64 lets the caller keep live locals in x19-x28
 * and the frame pointer x29 across the call.  With only sp installed, the child
 * resumes holding the CHILD THREAD's register values.  x29 (frame pointer) points
 * into the parent's stack and so is biased into the copy along with sp.
 */

#include "arch.hh"
#include <errno.h>
#include <string.h>
#include <cstdlib>
#include <osv/sched.hh>
#include <osv/fork.hh>

// pthread_atfork child-handler chain (defined in libc/pthread.cc), run in the
// child's context before it resumes user code.
extern "C" void __osv_run_atfork_child();

sched::thread *fork_thread(void *caller_ret, void *caller_sp,
                           void *resume_ctx, void **out_stack_to_free)
{
    auto ctx = static_cast<osv::fork_resume_ctx*>(resume_ctx);
    auto parent = sched::thread::current();
    auto parent_pinned_cpu = parent->pinned() ? sched::cpu::current() : nullptr;

    auto si = parent->get_stack_info();
    char *stack_base = static_cast<char*>(si.begin) + si.size;
    char *sp = static_cast<char*>(caller_sp);
    if (sp < static_cast<char*>(si.begin) || sp > stack_base) {
        return nullptr;
    }
    size_t stack_size = si.size;

    char *child_stack_mem = static_cast<char*>(malloc(stack_size));
    if (!child_stack_mem) {
        return nullptr;
    }
    // Copy ONLY the live top [caller_sp .. stack_base) into the top of the
    // child buffer (app stacks are demand-paged; copying from si.begin faults).
    char *child_base = child_stack_mem + stack_size;
    ptrdiff_t bias = child_base - stack_base;
    size_t live = static_cast<size_t>(stack_base - sp);
    memcpy(child_base - live, sp, live);
    char *child_sp = sp + bias;

    char *stack_to_free = child_stack_mem;

    // The child's resume context: the caller's callee-saved registers, with the
    // two STACK POINTERS (sp, and the frame pointer x29) biased into the child's
    // copy.  x19-x28 hold plain values and are carried across as-is.
    osv::fork_resume_ctx rc = *ctx;
    rc.sp = reinterpret_cast<u64>(child_sp);
    if (rc.x29 >= reinterpret_cast<u64>(sp) &&
        rc.x29 <= reinterpret_cast<u64>(stack_base)) {
        rc.x29 += bias;
    }

    // TLS: the child is a real OSv thread with its own fresh setup_tcb() block.
    // Only override tpidr_el0 if the parent had installed its own app TCB via
    // arch_prctl (parent_app_tcb != 0); otherwise keep the child's private OSv
    // TLS (the clean case for a musl app built against OSv's libc).
    u64 parent_app_tcb = parent->get_app_tcb();
    auto t = sched::thread::make([rc, parent_app_tcb] {
        if (parent_app_tcb) {
            asm volatile ("msr tpidr_el0, %0; isb" :: "r"(parent_app_tcb) : "memory");
        }
        // Run pthread_atfork child handlers in the child's context before
        // resuming user code.
        __osv_run_atfork_child();
        // Restore the caller's callee-saved context, install the private copied
        // stack, and branch to fork()'s return address with x0=0.  All loads are
        // based off x1 pointing at a LOCAL copy of the context; sp is installed
        // last so the sequence never invalidates its own base pointer.
        osv::fork_resume_ctx c = rc;
        asm volatile
          ("mov x1, %0        \n\t"   // x1 = &c (base; not restored)
           "ldr x19,  [x1, #0]   \n\t"
           "ldr x20,  [x1, #8]   \n\t"
           "ldr x21,  [x1, #16]  \n\t"
           "ldr x22,  [x1, #24]  \n\t"
           "ldr x23,  [x1, #32]  \n\t"
           "ldr x24,  [x1, #40]  \n\t"
           "ldr x25,  [x1, #48]  \n\t"
           "ldr x26,  [x1, #56]  \n\t"
           "ldr x27,  [x1, #64]  \n\t"
           "ldr x28,  [x1, #72]  \n\t"
           "ldr x29,  [x1, #80]  \n\t"   // frame pointer (biased)
           "ldr x2,   [x1, #96]  \n\t"   // x2 = caller pc (scratch)
           "ldr x3,   [x1, #88]  \n\t"   // x3 = biased child sp
           "mov sp, x3        \n\t"
           "mov x0, #0        \n\t"   // fork() returns 0 in the child
           "br x2             \n\t"   // resume in fork()'s caller
           : : "r"(&c)
           : "x0", "x1", "x2", "x3", "memory");
    }, sched::thread::attr().
        stack(4096 * 4).
        // Detached: nobody join()s the fork child (the parent reaps it via the
        // pid registry / waitpid, not sched::thread::join).  A detached thread
        // is handed to the reaper on completion, which runs our set_cleanup()
        // (freeing the copied stack and disposing the thread object, releasing
        // its application_runtime reference).  Without this the thread object
        // (and its app_runtime shared_ptr) would leak and OSv would hang at
        // shutdown -- see the cleanup comment in libc/process/fork.cc.
        detached(),
        false,
        true);
    t->set_app_tcb(parent->get_app_tcb());
    if (parent_pinned_cpu) {
        t->pin(parent_pinned_cpu);
    }
    if (out_stack_to_free) {
        *out_stack_to_free = stack_to_free;
    }
    return t;
}
