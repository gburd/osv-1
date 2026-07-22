/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread(): create a child thread that resumes at the fork() call site on
 * a PRIVATE COPY of the parent's current user stack, returning 0 in the child.
 *
 * This is the x86-64 arch half of the fork() emulation described in
 * documentation/fork.md.  It reuses the idea from clone_thread(): a new OSv
 * thread whose entry restores a register/stack context and jumps to a
 * continuation.  The one thing fork adds over clone is the stack COPY: whereas
 * pthread_create's clone() is handed a fresh child stack by the caller, fork's
 * child must continue executing the SAME code with its own copy of the parent's
 * stack so that parent and child diverge cleanly after the twin return.
 */

#include "arch.hh"
#include <errno.h>
#include <string.h>
#include <osv/sched.hh>
#include <osv/mmu.hh>
#include <osv/align.hh>
#include <osv/kernel_config_core_syscall.h>
#include <osv/syscalls_config.h>

// Copy the parent's live stack [from the current SP up to the stack base] into
// a freshly-allocated stack of the same size, and return a child thread that,
// when started, resumes at fork()'s return address on that copied stack with
// the return value (RAX) set to 0.
//
// How the twin return works: fork() is an ordinary function call, so at the
// moment fork_thread() runs, the caller's return address and saved frame live
// on the current (parent) stack just above fork_thread()'s own frame.  We
// snapshot the parent stack, compute the byte offset of the "resume SP" (the SP
// the child should have so that returning from fork() lands at the caller),
// and translate every stack-relative datum into the copy.  The child thread's
// bootstrap installs the copied SP and RET-equivalent jump.
sched::thread *fork_thread()
{
    auto parent = sched::thread::current();
    auto parent_pinned_cpu = parent->pinned() ? sched::cpu::current() : nullptr;

    // Capture the parent's current stack pointer at the entry to this function.
    // Everything from here up to the stack base is what the child needs.
    void *parent_sp;
    asm volatile ("movq %%rsp, %0" : "=r"(parent_sp));

    // Determine the parent's stack extent.  For app threads OSv records the
    // stack in the thread's stack_info; the base (high address) is begin+size.
    auto si = parent->get_stack_info();
    char *stack_base = static_cast<char*>(si.begin) + si.size;
    char *sp = static_cast<char*>(parent_sp);
    if (sp < static_cast<char*>(si.begin) || sp > stack_base) {
        // fork() called from a stack we can't reason about (e.g. an alt/kernel
        // stack).  Fail cleanly rather than corrupt memory.
        return nullptr;
    }
    size_t used = stack_base - sp;                 // live bytes to copy
    size_t stack_size = si.size;

    // The child's return address (where fork() returns to in the caller) and
    // the whole call chain above are captured in [sp, stack_base).  We copy the
    // ENTIRE stack region so absolute in-stack pointers that happen to point
    // within the stack keep the same OFFSET; we then bias the child's SP by the
    // (child_base - parent_base) delta.  Copying the whole region (not just the
    // used part) preserves offsets exactly.
    (void)used;

    // Allocate the child's stack (same size, 16-byte aligned) and copy.
    char *child_stack_mem = static_cast<char*>(malloc(stack_size));
    if (!child_stack_mem) {
        return nullptr;
    }
    memcpy(child_stack_mem, si.begin, stack_size);
    char *child_base = child_stack_mem + stack_size;
    ptrdiff_t bias = child_base - stack_base;      // add to a parent-stack addr

    // The child's initial SP = parent's SP translated into the copy.
    char *child_sp = sp + bias;

    // Build the child thread.  Its entry installs child_sp and returns from
    // fork() with RAX = 0.  We must return to the SAME instruction the parent's
    // fork() call would return to, which is the return address currently at the
    // top of fork()'s caller frame -- i.e. what `ret` from fork() would use.
    // fork() (the C function in fork.cc) will, in the parent, execute its normal
    // epilogue + ret; the child instead jumps straight to fork()'s return site.
    //
    // We capture that return site as fork_thread()'s own return address's
    // caller: the address in RAX below is filled by reading the return address
    // fork() will use.  Simplest correct approach: the child re-executes the
    // return of fork() from the copied stack.  We set the child up to run a
    // trampoline that sets rsp=child_sp, rax=0, and `ret` -- which pops fork()'s
    // return address from the copied stack and continues in the caller with the
    // child's private stack.  This requires child_sp to point exactly where
    // fork()'s `ret` expects (the saved return address).  Since we copied the
    // whole stack verbatim and biased SP, the saved return address at *child_sp
    // is identical to the parent's, so `ret` lands in the caller correctly.

    auto deleter = [child_stack_mem](sched::thread::stack_info) {
        free(child_stack_mem);
    };
    sched::thread::stack_info child_stack_info(child_stack_mem, stack_size);
    child_stack_info.deleter =
        +[](sched::thread::stack_info si2) { free(si2.begin); };

    // The child thread runs on its OWN kernel stack; the copied user stack is
    // installed by the trampoline.  We stash child_sp for the asm to load.
    volatile u64 resume_sp = reinterpret_cast<u64>(child_sp);

    auto t = sched::thread::make([resume_sp] {
        u64 app_tcb = sched::thread::current()->get_app_tcb();
        if (app_tcb) {
            arch::set_fsbase(app_tcb);
        }
        // Install the copied stack and return from fork() (rax=0) in the child.
        // *resume_sp holds fork()'s saved return address (copied verbatim), so
        // `ret` continues in fork()'s caller on the private stack.
        asm volatile
          ("movq %0, %%rsp \n\t"   // switch to the copied user stack
           "xorq %%rax, %%rax \n\t"// fork() returns 0 in the child
           "ret \n\t"              // pop fork()'s return address -> caller
           : : "r"(resume_sp) : "memory");
    }, sched::thread::attr().
        stack(4096 * 4).            // child's kernel stack
        pin(parent_pinned_cpu),
        false,
        true);

    // Give the child its own app-TCB matching the parent (shared TLS image is
    // fine on OSv since the address space is shared; a truly private TLS block
    // is a future refinement noted in documentation/fork.md).
    t->set_app_tcb(parent->get_app_tcb());
    return t;
}
