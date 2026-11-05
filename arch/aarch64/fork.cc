/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread() for aarch64 -- mirrors arch/x64/fork.cc.  The child resumes in
 * fork()'s CALLER on the SAME user stack virtual addresses the parent had -- no
 * stack relocation, no SP bias -- and with the caller's FULL callee-saved
 * register context restored, exactly as a normal `ret` from fork() would leave
 * it.  The child's address space (built by clone_address_space) maps the
 * parent's live stack VA range to freshly-allocated PRIVATE physical pages that
 * byte-copy the parent's stack, so the child sees identical stack contents at
 * identical addresses but writes to its own private frames.
 *
 * Why same-VA + full register restore (and NOT the earlier copy+bias): AAPCS64
 * code addresses saved frame pointers (x29), return addresses, and &local
 * pointers as absolute stack VAs, and keeps live values in callee-saved
 * registers (x19-x28) across calls.  Relocating the child stack to a different
 * VA and biasing SP leaves every saved x29/&local pointing at the PARENT's
 * stack (off by the bias), and simply `br`-ing to the return address skips
 * fork()'s epilogue so the caller resumes with fork()'s internal register
 * values.  Either corrupts a deep call chain: a shallow caller (tst-fork)
 * survives, but a child that keeps running forward in its caller holding live
 * state in x19-x28 (e.g. tst-fork-concfork-objlist's forker_thread, which keeps
 * its forker_arg* and loop counters across fork()) reads garbage and wild-
 * branches.  Keeping the child on the parent's exact VAs (private phys) AND
 * restoring the full caller register context (osv::fork_resume_ctx, captured at
 * fork() entry) makes the child continue in fork()'s caller as if fork() had
 * returned 0 -- the only correct way to fork a deep stack (see tst-fork-deep).
 */

#include "arch.hh"
#include <errno.h>
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
        return nullptr;   // caller SP not within the known user stack
    }

    // Same-VA stack: the child resumes on the parent's EXACT register context.
    // No copy and no bias -- clone_address_space() privatizes the parent's live
    // stack VA range into the child's address space (fresh private pages that
    // byte-copy the parent's stack), so these very addresses are valid and
    // private in the child.  Capture the resume context BY VALUE in the lambda
    // (the parent's on-stack ctx is gone by the time the child runs).
    (void)caller_ret;
    osv::fork_resume_ctx rc = *ctx;

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
        // Restore the caller's full callee-saved register context and resume in
        // fork()'s caller with return value 0, on the parent's exact stack VAs
        // (private phys in the child AS).  We base every load off a scratch
        // register (x9) that points at a LOCAL copy of the context, load SP
        // LAST (via x10, since `mov sp,Xn` needs a GPR source), and never put
        // x9 in the restore set, so the sequence never clobbers its own base.
        // Offsets match struct fork_resume_ctx { x19..x28, fp(x29), sp, pc }.
        osv::fork_resume_ctx c = rc;   // local copy the asm can address stably
        asm volatile
          ("mov  x9, %0        \n\t"   // x9 = &c (base; not restored)
           "ldr  x19, [x9, #0]  \n\t"
           "ldr  x20, [x9, #8]  \n\t"
           "ldr  x21, [x9, #16] \n\t"
           "ldr  x22, [x9, #24] \n\t"
           "ldr  x23, [x9, #32] \n\t"
           "ldr  x24, [x9, #40] \n\t"
           "ldr  x25, [x9, #48] \n\t"
           "ldr  x26, [x9, #56] \n\t"
           "ldr  x27, [x9, #64] \n\t"
           "ldr  x28, [x9, #72] \n\t"
           "ldr  x29, [x9, #80] \n\t"   // caller's frame pointer
           "ldr  x30, [x9, #96] \n\t"   // caller's return address (x30)
           "ldr  x10, [x9, #88] \n\t"   // caller's SP (parent's exact SP)
           "mov  sp, x10        \n\t"   // adopt the parent's exact SP, last
           "mov  x0, #0         \n\t"   // fork() returns 0 in the child
           "ret                 \n\t"   // resume in fork()'s caller (br x30)
           : : "r"(&c)
           : "x0", "x9", "x10", "x19", "x20", "x21", "x22", "x23", "x24",
             "x25", "x26", "x27", "x28", "x29", "x30", "memory");
    }, sched::thread::attr().
        stack(4096 * 4).
        // Detached: nobody join()s the fork child (the parent reaps it via the
        // pid registry / waitpid, not sched::thread::join).  A detached thread
        // is handed to the reaper on completion, which runs our set_cleanup()
        // (disposing the thread object, releasing its application_runtime
        // reference).  Without this the thread object (and its app_runtime
        // shared_ptr) would leak and OSv would hang at shutdown -- see the
        // cleanup comment in libc/process/fork.cc.
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
