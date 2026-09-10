/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread(): create a child thread that resumes in fork()'s CALLER, on a
 * private copy of the parent's user stack, returning 0 from fork() in the child.
 * The x86-64 arch half of the fork() emulation (see documentation/fork.md).
 *
 * fork() (libc/process/fork.cc) passes us the caller's resume point:
 *   caller_ret  = the address fork() would return to  (__builtin_return_address)
 *   caller_sp   = the parent's SP at fork()'s return   (fork()'s frame base)
 * We copy the parent stack region [caller_sp .. stack_base) into a fresh stack,
 * bias caller_sp into the copy, and start a child thread whose trampoline
 * restores the caller's callee-saved register context, sets rsp into the copy,
 * rax=0, and jumps to caller_ret -- i.e. the child returns from fork() with
 * value 0 on its own private stack, in the caller.
 *
 * Restoring the callee-saved registers is not optional: the trampoline jmps
 * straight to fork()'s return address, skipping fork()'s epilogue, and the SysV
 * ABI lets the caller keep live locals in rbx/rbp/r12-r15 across the call.  With
 * only rsp installed, the child resumes in its caller holding the CHILD THREAD's
 * register values, so a local the compiler parked in rbx reads as a kernel
 * pointer.  rbx/r12-r15 hold plain values and are carried across unchanged; rbp
 * is NOT restored, because this port relocates the stack and a frame pointer
 * would need a bias that is wrong for an outermost frame (see the comment at the
 * restore site).
 */

#include "arch.hh"
#include "tls-switch.hh"
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
        return nullptr;   // caller SP not within the known user stack
    }
    size_t stack_size = si.size;

    char *child_stack_mem = static_cast<char*>(malloc(stack_size));
    if (!child_stack_mem) {
        return nullptr;
    }
    // Copy ONLY the live top of the stack, [caller_sp .. stack_base), into the
    // TOP of the child buffer.  App (pthread) stacks are demand-paged: only the
    // used top is mapped, so copying from si.begin would fault on the first
    // unmapped page.  Keeping the copy at the top of the child buffer preserves
    // the base-relative bias so a biased SP resolves correctly.
    char *child_base = child_stack_mem + stack_size;
    ptrdiff_t bias = child_base - stack_base;
    size_t live = static_cast<size_t>(stack_base - sp);
    memcpy(child_base - live, sp, live);
    char *child_sp = sp + bias;

    char *stack_to_free = child_stack_mem;

    // The child's resume context: the caller's callee-saved registers, with rsp
    // pointed at the child's copied stack.
    //
    // rbx/r12-r15 hold plain VALUES and are carried across unchanged; those are
    // the ones that matter for correctness here, because they are where the
    // compiler parks a caller's live locals (an fd, a counter) across the call.
    //
    // rbp is deliberately NOT rebased.  This port RELOCATES the child's stack to
    // a different virtual address, so a frame pointer is only meaningful after a
    // bias, and a bias is only correct for a pointer that actually lies inside
    // the copied region [caller_sp, stack_base).  The outermost frame of a
    // thread (a fork() called directly from main()) has an rbp that does not,
    // and biasing it produced a wild pointer and a "missing symbol" fault in the
    // child.  Instead we keep fork()'s own frame pointer, which the existing
    // stack-copy machinery already leaves valid in the copy: the child resumes
    // with a correct rsp and correct value registers, and the caller re-derives
    // rbp from its own prologue/epilogue as normal.
    //
    // ponytail: no rbp rebase, so a child that unwinds THROUGH fork()'s caller
    // (a deep backtrace, a C++ exception crossing the fork point) can still see
    // a stale frame pointer.  The real fix is to stop relocating the stack and
    // give the child the parent's exact VAs with private physical pages, as the
    // address-space-aware fork does downstream; that removes the bias entirely.
    osv::fork_resume_ctx rc = *ctx;
    rc.rsp = reinterpret_cast<u64>(child_sp);

    // TLS handling.  The child is a real OSv sched::thread, so its constructor
    // already ran setup_tcb() and installed a FRESH, private OSv TLS block
    // (with its own errno and all libc __thread state).  Two cases:
    //
    //  (1) The app uses OSv's libc TLS (the normal dynamically-linked path,
    //      app_tcb == 0): the child's own fresh TCB is exactly right -- do NOT
    //      touch fsbase, let the child run on its private per-thread TLS.  This
    //      is the clean case and fork() "just works" for TLS.
    //  (2) The app installed its own TCB via arch_prctl(SET_FS) (app_tcb != 0,
    //      e.g. a glibc binary's __libc_setup_tls): the child would need a
    //      private COPY of that app TCB.  We do not duplicate it here yet;
    //      the child inherits the parent's app_tcb (shared), which is the
    //      documented multi-process-glibc limitation.  A musl app built against
    //      OSv's libc takes path (1) and avoids this entirely.
    u64 parent_app_tcb = parent->get_app_tcb();

    auto t = sched::thread::make([rc, parent_app_tcb] {
        // Only override the child's own (fresh) TLS if the parent had installed
        // an app TCB via arch_prctl; otherwise keep the child's private OSv TCB.
        if (parent_app_tcb) {
            arch::set_fsbase(parent_app_tcb);
        }
        // Run pthread_atfork child handlers in the child's context (e.g. reset
        // the malloc arena lock) before resuming user code.
        __osv_run_atfork_child();
        // Restore the caller's callee-saved context and resume in fork()'s caller
        // with return value 0, on the private copied stack.  All loads are based
        // off rax pointing at a LOCAL copy of the context, and rsp is loaded
        // last: rax is never in the restore set, so the sequence cannot clobber
        // its own base pointer.  Offsets match struct fork_resume_ctx
        // { rbx, rbp, r12, r13, r14, r15, rsp, rip }.
        osv::fork_resume_ctx c = rc;   // local copy the asm can address stably
        asm volatile
          ("movq %0, %%rax        \n\t"  // rax = &c (base; not restored)
           "movq  0(%%rax), %%rbx \n\t"  // rbp deliberately NOT restored
           "movq 16(%%rax), %%r12 \n\t"
           "movq 24(%%rax), %%r13 \n\t"
           "movq 32(%%rax), %%r14 \n\t"
           "movq 40(%%rax), %%r15 \n\t"
           "movq 56(%%rax), %%rcx \n\t"  // rcx = caller rip (scratch)
           "movq 48(%%rax), %%rsp \n\t"  // adopt the biased child stack pointer
           "xorq %%rax, %%rax     \n\t"  // fork() returns 0 in the child
           "jmpq *%%rcx           \n\t"  // resume in fork()'s caller
           : : "r"(&c) : "rax", "rcx", "memory");
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
    // The caller (fork.cc) owns the single cleanup; hand back the copied user
    // stack so it can be freed when the child is reaped.
    if (out_stack_to_free) {
        *out_stack_to_free = stack_to_free;
    }
    return t;
}
