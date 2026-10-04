/*
 * Copyright (C) 2026 Greg Burd
 * SPDX-License-Identifier: BSD-2-Clause
 */
// Separate from Unit A: public malloc's large fallback must not map or block
// in atomic context. Normal-context large allocation must still work.
#include <osv/kernel_config_fork.h>
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/wait.h>
#if CONF_fork
#include <osv/fork_arena.hh>
#include <osv/sched.hh>
#include <osv/irqlock.hh>

int main(int argc, char** argv)
{
    assert(argc == 3);
    bool irq_off = !strcmp(argv[1], "irq");
    bool large_probe = !strcmp(argv[2], "large");
    // Warm the small identity pool before entering the bounded atomic test.
    {
        fork_arena::kernel_heap_scope identity;
        auto p = malloc(32);
        assert(p && !fork_arena::contains(p));
        memset(p, 1, 32);
        free(p);
    }
    auto original = static_cast<unsigned char*>(malloc(32));
    assert(original && fork_arena::contains(original));
    memset(original, 0x39, 32);
    auto pid = fork();
    assert(pid >= 0);
    if (!pid) _exit(0);
    int status;
    assert(waitpid(pid, &status, 0) == pid);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    // Indirect calls plus -fno-builtin in the test build prevent malloc/free
    // optimization from deleting the calls whose context is under test.
    void* (*volatile allocate)(size_t) = malloc;
    irq_save_lock_type irq;
    if (irq_off) irq.lock(); else sched::preempt_disable();
    errno = 0;
    void* large = allocate(large_probe ? 4 * 1024 * 1024 : 4097);
    int large_errno = errno;
    if (irq_off) irq.unlock(); else sched::preempt_enable();
    free(large);
    assert(!large && large_errno == ENOMEM);

    void* aligned = original; // failed posix_memalign must not change output
    if (irq_off) irq.lock(); else sched::preempt_disable();
    auto small = static_cast<unsigned char*>(allocate(32));
    if (small) memset(small, 0x61, 32);
    errno = EDOM;
    int aligned_error = posix_memalign(&aligned, 8192, 32);
    int aligned_errno = errno;
    auto page = static_cast<unsigned char*>(allocate(4096));
    if (page) memset(page, 0x53, 4096);
    errno = 0;
    void* grown = realloc(original, 4 * 1024 * 1024);
    int grown_errno = errno;
    errno = 0;
    void* zeroed = calloc(1, 4 * 1024 * 1024);
    int zeroed_errno = errno;
    errno = 0;
    void* c_aligned = aligned_alloc(8192, 8192);
    int c_aligned_errno = errno;
    if (irq_off) irq.unlock(); else sched::preempt_enable();
    assert(small && !fork_arena::contains(small));
    for (unsigned i = 0; i < 32; ++i) assert(small[i] == 0x61);
    assert(aligned_error == ENOMEM && aligned == original && aligned_errno == EDOM);
    assert(page && !fork_arena::contains(page));
    for (unsigned i = 0; i < 4096; ++i) assert(page[i] == 0x53);
    assert(!grown && grown_errno == ENOMEM);
    assert(!zeroed && zeroed_errno == ENOMEM);
    assert(!c_aligned && c_aligned_errno == ENOMEM);
    for (unsigned i = 0; i < 32; ++i) assert(original[i] == 0x39);
    free(page);
    free(small);
    free(original);
    auto normal = static_cast<unsigned char*>(allocate(4 * 1024 * 1024));
    assert(normal);
    memset(normal, 0x42, 4 * 1024 * 1024);
    for (size_t i = 0; i < 4 * 1024 * 1024; ++i) assert(normal[i] == 0x42);
    free(normal);
    aligned = nullptr;
    errno = EDOM;
    assert(posix_memalign(&aligned, 8192, 8192) == 0);
    assert(aligned && errno == EDOM);
    memset(aligned, 0x75, 8192);
    free(aligned);
    puts("PASS: public atomic malloc fallback rejection, identity payload, and normal large allocation");
}
#else
int main() { puts("SKIP: requires CONF_fork=1"); }
#endif
