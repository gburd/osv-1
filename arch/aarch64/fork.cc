/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread() for aarch64 -- mirrors arch/x64/fork.cc (same-VA fork).  The
 * child resumes in fork()'s CALLER on the parent's EXACT stack VAs and with the
 * caller's full callee-saved register context restored, exactly as a normal
 * `ret` from fork() would leave it.  clone_address_space() privatizes the
 * forking thread's live stack into the child address space (fresh private pages
 * that byte-copy the parent's stack at the SAME VAs), so the child sees
 * identical stack contents at identical addresses but writes its own private
 * pages, and the fork bookkeeping (detached_state / wait_records that are
 * dereferenced cross-AS) stays coherent because every thread keeps its stack at
 * the same VA in every address space.  See arch/x64/fork.cc for the full
 * rationale (same-VA + full register restore is the only correct way to fork a
 * deep stack); the aarch64 differences are purely register names and the
 * TTBR0 (vs CR3) switch, which happens in arch/aarch64/sched.S at the context
 * switch when the incoming thread's address space differs from the live one.
 */

#include "arch.hh"
#include <errno.h>
#include <string.h>
#include <cstdlib>
#include <osv/sched.hh>
#include <osv/fork.hh>
#include <osv/fork_arena.hh>
#include <osv/debug.hh>

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
        return nullptr;   // caller SP not within the known user stack
    }

    // Same-VA stack: the child resumes on the parent's EXACT register context.
    // No copy and no bias -- clone_address_space() privatizes the parent's live
    // stack VA range into the child's address space, so these very addresses
    // are valid and private in the child.  Capture the resume context by value
    // in the lambda (the parent's on-stack ctx is gone by the time the child
    // runs).
    (void)caller_ret;
    osv::fork_resume_ctx rc = *ctx;

    // TLS: the child is a real OSv sched::thread with its own fresh setup_tcb()
    // block.  Only override tpidr_el0 if the parent installed its own app TCB
    // (parent_app_tcb != 0, a foreign glibc app); otherwise keep the child's
    // private OSv TLS (the clean musl-on-OSv case).
    u64 parent_app_tcb = parent->get_app_tcb();

    // Allocate the child sched::thread object (and its detached_state, which
    // holds the scheduler status word walked cross-AS by thread::wake_impl) on
    // the identity kernel heap, NOT the forking backend's COW fork arena -- a
    // cross-AS wakeup must be able to resolve the woken thread's scheduler
    // state at a VA mapped verbatim in every address space.  (Same rationale as
    // arch/x64/fork.cc.)
    fork_arena::kernel_heap_scope kh_child_thread;
    auto t = sched::thread::make([rc, parent_app_tcb] {
        if (parent_app_tcb) {
            asm volatile ("msr tpidr_el0, %0; isb" :: "r"(parent_app_tcb) : "memory");
        }
        // Run pthread_atfork child handlers in the child's context (e.g. reset
        // the malloc arena lock) before resuming user code.
        __osv_run_atfork_child();
        // Restore the caller's callee-saved registers (x19-x28), frame pointer
        // (x29) and stack pointer, then branch to fork()'s caller with x0=0.
        // We load everything off a base register (x9) pointing at a LOCAL copy
        // of the context, restore sp LAST, and never make x9 one of the
        // restored registers, so the load sequence never clobbers its own base.
        // Offsets match struct fork_resume_ctx { x19..x28, fp(x29), sp, lr }.
        volatile osv::fork_resume_ctx c = rc;   // local the asm can address stably
        asm volatile
          ("mov  x9, %0            \n\t"  // x9 = &c (base; not restored)
           "ldp  x19, x20, [x9, #0]   \n\t"
           "ldp  x21, x22, [x9, #16]  \n\t"
           "ldp  x23, x24, [x9, #32]  \n\t"
           "ldp  x25, x26, [x9, #48]  \n\t"
           "ldp  x27, x28, [x9, #64]  \n\t"
           "ldr  x29, [x9, #80]       \n\t"  // frame pointer (x29)
           "ldr  x30, [x9, #96]       \n\t"  // lr = caller return address
           "ldr  x10, [x9, #88]       \n\t"  // x10 = caller sp (scratch)
           "mov  sp, x10              \n\t"  // adopt the parent's exact sp
           "mov  x0, #0               \n\t"  // fork() returns 0 in the child
           "ret                       \n\t"  // resume in fork()'s caller (via x30)
           : : "r"(&c)
           : "x0", "x9", "x10", "x19", "x20", "x21", "x22", "x23", "x24",
             "x25", "x26", "x27", "x28", "x29", "x30", "memory");
    }, sched::thread::attr().
        stack(4096 * 4).
        // Detached: the parent reaps the child via the pid registry / waitpid,
        // not sched::thread::join.  The reaper runs our set_cleanup() (destroys
        // the child AS, disposes the thread object, releasing its
        // application_runtime reference) -- see libc/process/fork.cc.
        detached(),
        false,
        true);
    t->set_app_tcb(parent->get_app_tcb());
    if (parent_pinned_cpu) {
        t->pin(parent_pinned_cpu);
    }
    // Same-VA: no separate user-stack buffer to free (the child's stack pages
    // are owned by its address space and freed on destroy_address_space()).
    if (out_stack_to_free) {
        *out_stack_to_free = nullptr;
    }
    return t;
}
