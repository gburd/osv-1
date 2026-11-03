/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * REGRESSION TEST for the fork-arena VA-exhaustion / RAM-growth leak that the
 * whole-arena per-AS-window redesign (core/fork_arena.cc) fixes.
 *
 * THE BUG (pre-fix, the OLD shared-bump arena):
 *   The fork COW heap arena was a single fixed VA region carved by a global
 *   monotonic bump pointer whose VA was NEVER returned on child reap.  Under
 *   sustained fork-per-connection churn the bump exhausts (the f391 commit put
 *   the wall near ~700 backends for the default size; the b9 analysis saw the
 *   shared-bump design hit a wall near ~8080 forks), after which every forked
 *   child's heap falls back to the identity heap, which destroy_address_space
 *   never frees -- a steady per-backend leak that grows mem_free DOWNWARD
 *   without bound and eventually OOMs the guest.  So on the OLD arena, free
 *   memory TRENDS DOWN across fork/exit churn and/or a fork eventually fails.
 *
 * THE FIX (per-AS windows):
 *   Each live address space owns one disjoint VA window; the whole window is
 *   reclaimed wholesale by destroy_address_space's page teardown on reap.  RAM
 *   therefore tracks the LIVE heap (freed on reap), not lifetime churn, and
 *   there is no shared monotonic bump to exhaust.  So on the FIXED arena, free
 *   memory stays FLAT across arbitrarily many fork/exit cycles and no fork
 *   fails for arena reasons.
 *
 * WHAT THIS TEST DOES (PostgreSQL-free, runs on plain KVM):
 *   A single sequential loop of fork()/_exit() cycles -- WELL PAST the old wall
 *   (default 30000 cycles) -- with a periodic fork()+execve() cycle mixed in
 *   (the child exec's /tests/payload-exit7.so, a fresh ELF namespace, exercising
 *   the execve teardown path too).  Every child does a small post-fork heap
 *   allocation + write (so the arena actually serves the child) then _exit()s;
 *   the parent waitpid()s.  Free memory (sysconf(_SC_AVPHYS_PAGES)) is sampled
 *   on a timeline.  The test asserts:
 *     - no fork() ever fails for want of resources (the VA-exhaustion symptom);
 *     - free memory does not trend downward past a generous slack across the
 *       whole run (the RAM-growth-leak symptom): final and worst-case free
 *       memory stay within SLACK_MB of the post-warmup baseline.
 *
 *   On the OLD shared-bump arena this FAILS (free memory marches down and/or a
 *   fork fails past the wall).  On the per-AS-window arena it PASSES (flat).
 *
 * Run (CONF_fork build):
 *   ./scripts/build conf_fork=1 image=tests
 *   ./scripts/run.py -c 2 -e "/tests/tst-fork-arena-exhaust.so [cycles]"
 *
 * Requires CONF_fork; without it the test prints SKIP and exits 0.
 */

#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <osv/kernel_config_fork.h>

static long free_mb(void)
{
    long pages = sysconf(_SC_AVPHYS_PAGES);
    long pgsz  = sysconf(_SC_PAGESIZE);
    if (pages < 0 || pgsz < 0) return -1;
    return (long)(((long long)pages * pgsz) >> 20);
}

#if !CONF_fork
int main()
{
    printf("tst-fork-arena-exhaust: CONF_fork disabled, not applicable; SKIP\n");
    return 0;
}
#else

// Child work: allocate + write a few KB from the (COW/arena) heap so the arena
// actually serves this child, then exit without freeing (process teardown must
// reclaim it).  Mirrors a backend that palloc's a bit then exits.
static void child_body(void)
{
    const int N = 8;
    void *p[N];
    for (int i = 0; i < N; i++) {
        p[i] = malloc(4096 + i * 512);
        if (p[i]) memset(p[i], 0x5a, 4096 + i * 512);
    }
    // intentionally do NOT free: the AS teardown on _exit must reclaim it
    _exit(0);
}

int main(int argc, char **argv)
{
    long cycles = 30000;                 // WELL past the old ~8080-fork wall
    if (argc > 1) { cycles = strtol(argv[1], 0, 10); if (cycles <= 0) cycles = 30000; }
    const long SLACK_MB = 64;            // generous; a real leak blows through it
    const long EXECVE_EVERY = 500;       // mix in a fork+execve cycle periodically

    setvbuf(stdout, 0, _IONBF, 0);
    printf("=== tst-fork-arena-exhaust: %ld fork/exit cycles (execve every %ld) ===\n",
           cycles, EXECVE_EVERY);

    // Warm up a few cycles so one-time allocations settle, then baseline.
    for (int i = 0; i < 8; i++) {
        pid_t p = fork();
        if (p == 0) child_body();
        if (p < 0) { printf("FAIL: warmup fork failed errno=%d\n", errno); return 1; }
        int st; waitpid(p, &st, 0);
    }
    long baseline = free_mb();
    long worst = baseline;               // lowest free seen
    printf("baseline free: %ld MB\n", baseline);

    long sample_every = cycles / 30; if (sample_every < 1) sample_every = 1;

    for (long i = 1; i <= cycles; i++) {
        pid_t p = fork();
        if (p < 0) {
            long now = free_mb();
            printf("FAIL: fork cycle %ld failed errno=%d (EMFILE=%d ENOMEM=%d); "
                   "free now=%ld MB baseline=%ld MB -- VA/RAM EXHAUSTION\n",
                   i, errno, errno == EMFILE, errno == ENOMEM, now, baseline);
            return 1;
        }
        if (p == 0) {
            if (EXECVE_EVERY > 0 && (i % EXECVE_EVERY) == 0) {
                char *const av[] = { (char*)"/tests/payload-exit7.so", 0 };
                char *const ev[] = { 0 };
                execve("/tests/payload-exit7.so", av, ev);
                _exit(0);           // exec failed: still exit cleanly
            }
            child_body();
        }
        int st; waitpid(p, &st, 0);

        if (i % sample_every == 0 || i == cycles) {
            long now = free_mb();
            if (now >= 0 && now < worst) worst = now;
            printf("cycle %6ld: free = %ld MB (baseline %ld, delta %+ld, worst %ld)\n",
                   i, now, baseline, now - baseline, worst);
        }
    }

    long final_free = free_mb();
    long drop_final = baseline - final_free;      // positive == memory lost
    long drop_worst = baseline - worst;
    printf("final free = %ld MB, baseline = %ld MB, lost(final) = %+ld MB, "
           "lost(worst) = %+ld MB\n", final_free, baseline, drop_final, drop_worst);

    if (drop_final > SLACK_MB || drop_worst > SLACK_MB) {
        printf("FAIL: free memory fell past slack across %ld cycles -- arena "
               "VA-exhaustion / RAM-growth LEAK (lost %+ld MB, slack %ld)\n",
               cycles, drop_final > drop_worst ? drop_final : drop_worst, SLACK_MB);
        printf("=== tst-fork-arena-exhaust: FAILED ===\n");
        return 1;
    }
    printf("PASS: free memory flat (within %ld MB) across %ld fork/exit cycles; "
           "no fork failed -- arena tracks live heap, not churn\n", SLACK_MB, cycles);
    printf("=== tst-fork-arena-exhaust: OK ===\n");
    return 0;
}
#endif // CONF_fork
