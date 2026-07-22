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
 * bias caller_sp into the copy, and start a child thread whose trampoline sets
 * rsp=child_sp, rax=0, and jumps to caller_ret -- i.e. the child returns from
 * fork() with value 0 on its own private stack, in the caller.
 */

#include "arch.hh"
#include "tls-switch.hh"
#include "msr.hh"
#include <errno.h>
#include <string.h>
#include <cstdlib>
#include <osv/sched.hh>

sched::thread *fork_thread(void *caller_ret, void *caller_sp, void **out_stack_to_free)
{
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

    volatile u64 resume_sp = reinterpret_cast<u64>(child_sp);
    volatile u64 resume_pc = reinterpret_cast<u64>(caller_ret);
    char *stack_to_free = child_stack_mem;

    // Capture the parent's ACTUAL fsbase (its live TLS base).  app_tcb only
    // records a base for threads whose TLS was installed via arch_prctl(SET_FS);
    // an app's main thread can have app_tcb==0 while running on a real non-zero
    // fsbase.  The child must resume on the SAME TLS the caller used, so read
    // the live fsbase directly and restore it when app_tcb is unset.
    // NOTE: the child SHARES this TLS block with the parent -- OSv fork() does
    // not give the child a private TLS copy.  That is fine for OSv-native code
    // and short fork+exec/fork+_exit paths, but a glibc app that relies on
    // per-process private TLS after fork (e.g. multi-backend PostgreSQL) will
    // collide.  A private-TLS-per-child copy is a documented future step (see
    // documentation/fork.md).
    u64 parent_fsbase = processor::rdmsr(msr::IA32_FS_BASE);

    auto t = sched::thread::make([resume_sp, resume_pc, parent_fsbase] {
        u64 app_tcb = sched::thread::current()->get_app_tcb();
        u64 tls = app_tcb ? app_tcb : parent_fsbase;
        if (tls) {
            arch::set_fsbase(tls);
        }
        asm volatile
          ("movq %0, %%rsp \n\t"    // install the private copied stack
           "xorq %%rax, %%rax \n\t" // fork() returns 0 in the child
           "jmpq *%1 \n\t"          // resume in fork()'s caller
           : : "r"(resume_sp), "r"(resume_pc) : "memory");
    }, sched::thread::attr().
        stack(4096 * 4),
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
