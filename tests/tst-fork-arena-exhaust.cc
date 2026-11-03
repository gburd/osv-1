/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * REGRESSION TEST for the fork-arena VA-exhaustion / identity-heap-fallback
 * leak that the whole-arena per-AS-window redesign (core/fork_arena.cc) fixes.
 *
 * THE OLD FAILURE MODE (per f391e7c2a): the fork COW heap arena was a single
 * fixed 512 MiB VA region carved by a GLOBAL monotonic bump pointer whose VA is
 * NEVER returned on child reap.  So the bump advances by every forked child's
 * heap high-water and only ever goes up.  Once the cumulative carved VA exceeds
 * 512 MiB the bump is EXHAUSTED; from then on every forked child's heap falls
 * back to the identity heap, which destroy_address_space never frees -- a
 * ~per-backend-heap leak (f391 cites ~0.77 MiB/backend) that then grows RAM
 * without bound and OOMs.  The wall is near ~N forks where N*per_child_heap ~
 * 512 MiB (f391 cites ~700 backends for a realistic heap).
 *
 * THE FIX: per-AS windows reaped wholesale by destroy_address_space -> carved VA
 * IS returned on reap -> no global monotonic bump, no wall, no identity-heap
 * fallback.  RAM tracks the LIVE heap, not lifetime churn.
 *
 * WHAT THIS TEST DOES (PostgreSQL-free): sequential fork cycles where the CHILD
 * touches a PG-backend-like heap (default 1 MiB malloc+write) then exits, run
 * WELL PAST the old wall (default 4000 cycles => ~4 GiB of cumulative carved VA,
 * far over the 512 MiB bump).  Free memory (sysconf(_SC_AVPHYS_PAGES)) is
 * sampled on a timeline; the per-sample drop is printed so a KNEE (the slope
 * jumping from the substrate baseline to ~per-child-heap once the bump
 * exhausts) is visible.
 *
 * Args: [cycles] [child_heap_kb] [free_before_exit:0|1]
 *   free_before_exit=0 (default): child does NOT free (process teardown must
 *     reclaim); 1: child frees then exits (isolates teardown vs in-child free).
 *
 * VERDICT: the test asserts no fork fails AND the steady-state (second-half)
 * free-memory loss per fork stays under a quarter of the child heap.  On the
 * OLD shared-bump arena the bump runs out within the first few hundred forks,
 * after which every fork leaks its whole child heap (FAIL).  On the
 * per-AS-window arena only the small fork/reap substrate cost remains (PASS).
 * A first-half vs second-half slope comparison does NOT work: the wall is hit
 * so early that both halves leak at the same rate.
 *
 * Requires CONF_fork; otherwise prints SKIP and exits 0.
 */

#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <osv/kernel_config_fork.h>

static long free_kb(void)
{
    long pages = sysconf(_SC_AVPHYS_PAGES);
    long pgsz  = sysconf(_SC_PAGESIZE);
    if (pages < 0 || pgsz < 0) return -1;
    return (long)(((long long)pages * pgsz) >> 10);
}

#if !CONF_fork
int main() { printf("tst-fork-arena-exhaust: CONF_fork disabled; SKIP\n"); return 0; }
#else

static void child_body(long heap_kb, int free_before_exit)
{
    // Touch a PG-backend-like amount of heap so the child actually carves arena
    // VA (the OLD global bump only advances when a child allocates).  Allocate
    // in 64 KiB chunks and write each page so it is resident + carved.
    const long CHUNK = 64 * 1024;
    long n = (heap_kb * 1024 + CHUNK - 1) / CHUNK;
    char **p = (char **)malloc(n * sizeof(char *));
    for (long i = 0; i < n; i++) {
        p[i] = (char *)malloc(CHUNK);
        if (p[i]) memset(p[i], 0x5a, CHUNK);
    }
    if (free_before_exit) {
        for (long i = 0; i < n; i++) free(p[i]);
        free(p);
    }
    _exit(0);
}

int main(int argc, char **argv)
{
    long cycles  = (argc > 1) ? strtol(argv[1], 0, 10) : 4000;
    long heap_kb = (argc > 2) ? strtol(argv[2], 0, 10) : 1024;   // ~1 MiB/child
    int  freeit  = (argc > 3) ? atoi(argv[3]) : 0;
    if (cycles <= 0) cycles = 4000;
    if (heap_kb <= 0) heap_kb = 1024;

    setvbuf(stdout, 0, _IONBF, 0);
    printf("=== tst-fork-arena-exhaust: %ld cycles, child heap ~%ld KiB, "
           "free_before_exit=%d ===\n", cycles, heap_kb, freeit);
    printf("(old 512 MiB bump wall ~ %ld forks at this heap size)\n",
           (512L * 1024) / (heap_kb > 0 ? heap_kb : 1));

    // Warm up, then baseline.
    for (int i = 0; i < 8; i++) {
        pid_t p = fork();
        if (p == 0) child_body(heap_kb, freeit);
        if (p < 0) { printf("FAIL: warmup fork failed errno=%d\n", errno); return 1; }
        int st; waitpid(p, &st, 0);
    }
    long baseline = free_kb();
    long prev = baseline;
    long first_half_drop = 0, second_half_drop = 0, half = cycles / 2;
    long sample_every = cycles / 40; if (sample_every < 1) sample_every = 1;
    printf("baseline free: %ld KiB (%ld MiB)\n", baseline, baseline >> 10);

    for (long i = 1; i <= cycles; i++) {
        pid_t p = fork();
        if (p < 0) {
            long now = free_kb();
            printf("FAIL: fork cycle %ld failed errno=%d (ENOMEM=%d); free now=%ld "
                   "MiB baseline=%ld MiB -- VA/RAM EXHAUSTION at the wall\n",
                   i, errno, errno == ENOMEM, now >> 10, baseline >> 10);
            return 1;
        }
        if (p == 0) child_body(heap_kb, freeit);
        int st; waitpid(p, &st, 0);

        if (i % sample_every == 0 || i == cycles) {
            long now = free_kb();
            long d = prev - now;          // KiB lost since last sample
            if (i <= half) first_half_drop += d; else second_half_drop += d;
            printf("cycle %5ld: free = %ld MiB (delta %+ld MiB, step %+ld KiB/%ld f)\n",
                   i, now >> 10, (now - baseline) >> 10, -d, sample_every);
            prev = now;
        }
    }

    long final_free = free_kb();
    long total_lost_mib = (baseline - final_free) >> 10;
    // Slope in KiB per 1000 forks, first vs second half.
    double fh = half ? (double)first_half_drop  / half  * 1000.0 : 0;
    double sh = (cycles - half) ? (double)second_half_drop / (cycles - half) * 1000.0 : 0;
    printf("SLOPE: first-half %.0f KiB/1k forks, second-half %.0f KiB/1k forks; "
           "total lost %ld MiB over %ld forks\n", fh, sh, total_lost_mib, cycles);

    // Gate the steady-state (second-half) loss per fork against the child heap.
    // The fork/reap substrate itself loses ~10 KiB/fork; the identity-heap
    // fallback loses the whole child heap.  heap_kb/4 separates them >20x.
    double per_fork_kib = sh / 1000.0;
    double limit_kib = heap_kb / 4.0;
    printf("GATE: steady-state loss %.1f KiB/fork (limit %.1f = child heap/4)\n",
           per_fork_kib, limit_kib);
    if (per_fork_kib > limit_kib) {
        printf("FAIL: losing %.1f KiB per fork of a %ld KiB child heap -- child "
               "heap not returned on reap (bump wall / identity-heap fallback)\n",
               per_fork_kib, heap_kb);
        printf("=== tst-fork-arena-exhaust: FAILED ===\n");
        return 1;
    }
    printf("PASS: no fork failed; child heap returned on reap (2nd half %.0f, "
           "1st half %.0f KiB/1k forks)\n", sh, fh);
    printf("=== tst-fork-arena-exhaust: OK ===\n");
    return 0;
}
#endif
