/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * fork_thread() for aarch64.
 *
 * The x86-64 implementation (arch/x64/fork.cc) copies the parent's user stack
 * and resumes the child at fork()'s return site with x0/rax=0.  The aarch64
 * port of the same mechanism is a follow-up; until then fork() returns ENOSYS
 * on aarch64 rather than silently misbehaving.
 */

#include <osv/sched.hh>
#include <osv/kernel_config_core_syscall.h>
#include <osv/syscalls_config.h>

sched::thread *fork_thread()
{
    // Not yet implemented on aarch64 (needs the stack-copy + x0=0 resume
    // trampoline analogous to arch/x64/fork.cc).  Returning nullptr makes
    // fork() fail with ENOMEM/ENOSYS rather than corrupt memory.
    return nullptr;
}
