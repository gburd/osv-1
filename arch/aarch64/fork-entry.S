/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * aarch64 fork() entry.  GCC/aarch64 does not honor __attribute__((naked)) for
 * C functions, so the context-capturing fork() shim is written in assembly.
 *
 * At the very first instruction of fork(), x19-x28 hold the caller's callee-
 * saved values, x29 is the caller's frame pointer, x30 is the return address
 * into fork()'s caller, and SP is the caller's stack pointer.  We snapshot all
 * of them into a struct fork_resume_ctx on the stack and tail-call
 * fork_impl(&ctx) (libc/process/fork.cc), which does the real fork work and
 * returns the child pid (in the parent) in w0.  The forked CHILD does NOT
 * return through here -- it is a separate sched::thread that resumes directly
 * in fork()'s caller via the trampoline in arch/aarch64/fork.cc, restoring this
 * exact captured context.
 *
 * struct fork_resume_ctx layout (include/osv/fork.hh):
 *   x19 x20 x21 x22 x23 x24 x25 x26 x27 x28   (offsets 0..72)
 *   fp(x29)@80  sp@88  lr(x30)@96             (104 bytes total)
 */

.global fork
.type fork, %function
fork:
        sub     sp, sp, #112            // room for the 104-byte ctx (16-aligned)
        stp     x19, x20, [sp, #0]
        stp     x21, x22, [sp, #16]
        stp     x23, x24, [sp, #32]
        stp     x25, x26, [sp, #48]
        stp     x27, x28, [sp, #64]
        str     x29, [sp, #80]          // fp = caller's frame pointer
        add     x9, sp, #112            // x9 = caller's SP (before our sub)
        str     x9, [sp, #88]           // sp = caller's SP
        str     x30, [sp, #96]          // lr = caller's return address

        stp     x29, x30, [sp, #-16]!   // real frame for the call
        mov     x29, sp
        add     x0, sp, #16             // x0 = &ctx (just above our frame)
        bl      fork_impl               // -> child pid in w0 (parent path)
        ldp     x29, x30, [sp], #16
        add     sp, sp, #112            // pop the ctx
        ret
.size fork, . - fork
