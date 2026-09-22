/*
 * bench-alloc.c -- ONE source, three arms (OSv+musl, Linux+glibc, Linux+musl).
 *
 * Reproduces the SHAPE of PostgreSQL's parser allocation pattern, not PG:
 *   - many small allocations in the parse-node size classes (24..512 B),
 *   - short-lived: a live ring of `depth` pointers, oldest freed on each alloc,
 *   - a controlled fraction of frees performed on a DIFFERENT CPU than the
 *     allocation (MODE T, threads pinned 1:1 to CPUs),
 *   - MODE P: the same loop run by N FORKED SINGLE-THREADED PROCESSES, which is
 *     what a PostgreSQL backend actually is.
 *
 * *** THE SLOPE TEST (MODE P) IS THE PRIMARY EXPERIMENT. ***
 * core/fork_arena.cc:101 slot_for() linear-scans a 256-entry table to find the
 * CURRENT ADDRESS SPACE's free-list, and is called from BOTH alloc (:207) and
 * free (:273).  Slots pack from index 0, so the Nth live process pays ~N
 * iterations per malloc AND per free.  PREDICTION: CPU-ns per alloc+free pair is
 * LINEAR IN THE CHILD'S SLOT INDEX.  Children fork in order and each claims its
 * slot with a first malloc before the next child is forked, so child index ==
 * slot index (+1 for the parent).  A FLAT slope REFUTES the mechanism.  Linux
 * has no such table and is the control that must come out flat.  This tests a
 * SLOPE, not merely "more processes is slower".
 *
 * *** TWO CONFOUNDS, BOTH DEFEATED BY CONSTRUCTION (both were seen locally) ***
 * 1. OVERSUBSCRIPTION.  128 processes on 32 vCPU get ~1/4 CPU each, so WALL time
 *    per pair rises ~4x for reasons that have nothing to do with the allocator.
 *    Measured locally: wall-derived ns/pair "rose" 29.9 -> 349.7 from 8 to 128
 *    procs on 8 CPUs, which is pure oversubscription and would have been a
 *    fabricated confirmation.  FIX: every number is CPU time from
 *    CLOCK_THREAD_CPUTIME_ID (OSv implements it at libc/time.cc:94 via
 *    thread_clock(); Linux natively), so descheduled time is excluded.
 * 2. FORK STAGGER + UNEQUAL WORK.  FIX: a start barrier releases all children
 *    together, and each child does a FIXED NUMBER OF PAIRS (-n), so every child
 *    performs identical work and only its cost per pair can differ.
 *
 * MODE T's cross-CPU handoff is BATCHED on purpose: an unbatched per-pointer
 * handoff costs a remote cache-line transfer per free, several times a
 * malloc+free pair, which swamps the quantity under test (measured 30 -> 236
 * ns/pair on an idle box, i.e. the harness, not the allocator).
 *
 * -A runs a FIXED MATRIX so every arm executes byte-identical work from one
 * invocation (the OSv arm has no shell: the boot cmdline runs the binary once).
 * -C runs a NON-FATAL accounting self-check first (a failed assert would cost
 * the whole run, and on the OSv arm a run costs a boot).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <pthread.h>
#include <sched.h>
#include <unistd.h>
#include <time.h>
#include <sys/wait.h>
#include <errno.h>

#define BATCH 64        /* pointers per published handoff slot */
#define RINGSL 1024     /* published slots in flight per partner queue */
#define DRAINMAX 8      /* batches drained per iter: consumer must outpace producer */
#define MAXTHR 256
#define MAXKID 256

/* Parse-node-ish size distribution: weighted to the small end, max 512 B.
 * Deterministic table + deterministic LCG => every arm sees the SAME sequence. */
static const unsigned SZ[16] = {24,32,32,40,48,48,64,64,80,96,112,128,160,200,256,512};

struct pairq {                       /* SPSC queue of BATCHes (thread's inbox) */
    void *slot[RINGSL][BATCH];
    int cnt[RINGSL];
    unsigned head; char p1[64];
    unsigned tail; char p2[64];
};

struct tctx {
    pthread_t th;
    int id, nthr, depth, xfrac, pin, barrier;
    uint64_t target;                 /* pairs to perform (fixed work) */
    uint64_t rng;
    uint64_t allocs, remote_frees, local_frees, ring_full, drained, bytes;
    double cpu_s, wall_s;            /* THIS worker's own CPU and wall time */
    double cpu_main, cpu_coop;       /* main loop vs cooperative-drain CPU */
    int cpu_start, cpu_end;
    void **ring;
    struct pairq *inbox, *outbox;
    void *batch[BATCH];
    int nbatch;
    char pad[128];
};

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

/* CPU time of the CALLING THREAD.  Falls back to wall if unsupported, and says
 * so via cpuclock_ok, so a silent 0 can never masquerade as a fast arm. */
static int cpuclock_ok = 1;
static double cpu_s(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) {
        cpuclock_ok = 0;
        return now_s();
    }
    if (ts.tv_sec == 0 && ts.tv_nsec == 0) cpuclock_ok = 0;
    return (double)ts.tv_sec + 1e-9 * (double)ts.tv_nsec;
}

static inline uint64_t nextr(uint64_t *s)
{
    *s = *s * 6364136223846793005ULL + 1442695040888963407ULL;
    return *s >> 17;
}

/* OSv's libc has NO pthread_barrier_* (absent from libc/pthread.cc), so the
 * start barrier is hand-rolled.  Without it, thread-start stagger lets early
 * threads overrun a partner that has not started yet, the handoff ring
 * overflows, and the ACHIEVED cross-CPU free fraction collapses -- measured
 * locally at 5.5% when 100% was requested, i.e. the arm silently would not be
 * running the experiment its own label claims. */
static volatile unsigned g_bar;
static volatile unsigned g_done;
static void barrier_wait(int nthr)
{
    __atomic_add_fetch(&g_bar, 1, __ATOMIC_ACQ_REL);
    while ((int)__atomic_load_n(&g_bar, __ATOMIC_ACQUIRE) < nthr) sched_yield();
}

static void pin_to(int cpu)
{
    long nc = sysconf(_SC_NPROCESSORS_ONLN);
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu % (int)(nc > 0 ? nc : 1), &set);
    sched_setaffinity(0, sizeof(set), &set);
}

static int publish(struct tctx *c)
{
    struct pairq *q = c->outbox;
    unsigned h = q->head;
    if (h - __atomic_load_n(&q->tail, __ATOMIC_ACQUIRE) >= RINGSL) return 0;
    unsigned i = h % RINGSL;
    memcpy(q->slot[i], c->batch, sizeof(void *) * (size_t)c->nbatch);
    q->cnt[i] = c->nbatch;
    __atomic_store_n(&q->head, h + 1, __ATOMIC_RELEASE);
    c->nbatch = 0;
    return 1;
}

static int drain_one(struct tctx *c)
{
    struct pairq *q = c->inbox;
    unsigned t = q->tail;
    if (__atomic_load_n(&q->head, __ATOMIC_ACQUIRE) == t) return 0;
    unsigned i = t % RINGSL;
    int n = q->cnt[i];
    for (int k = 0; k < n; k++) free(q->slot[i][k]);
    __atomic_store_n(&q->tail, t + 1, __ATOMIC_RELEASE);
    return n;
}

/* The producer publishes only once per BATCH remote frees, so the consumer must
 * be allowed to clear more than one batch per iteration or the ring fills. */
static int drain_some(struct tctx *c)
{
    int n = 0;
    for (int i = 0; i < DRAINMAX; i++) {
        int k = drain_one(c);
        if (!k) break;
        n += k;
    }
    return n;
}

static inline int inbox_nonempty(struct tctx *c)
{
    return __atomic_load_n(&c->inbox->head, __ATOMIC_ACQUIRE) != c->inbox->tail;
}

static void *worker(void *arg)
{
    struct tctx *c = arg;
    if (c->pin) {
        cpu_set_t set;
        CPU_ZERO(&set);
        CPU_SET(c->id % (int)sysconf(_SC_NPROCESSORS_ONLN), &set);
        pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
    }
    c->cpu_start = sched_getcpu();
    c->ring = calloc((size_t)c->depth, sizeof(void *));
    if (!c->ring) { fprintf(stderr, "FATAL ring\n"); exit(2); }
    if (c->barrier > 1) barrier_wait(c->barrier);

    double c0 = cpu_s(), w0 = now_s();
    int ri = 0;
    for (uint64_t n = 0; n < c->target; n++) {
        uint64_t r = nextr(&c->rng);
        unsigned sz = SZ[r & 15];
        char *p = malloc(sz);
        if (!p) { fprintf(stderr, "FATAL malloc %u\n", sz); exit(2); }
        p[0] = 1; p[sz - 1] = 1;      /* touch both ends, like a written node */
        c->allocs++;
        c->bytes += sz;
        void *old = c->ring[ri];
        c->ring[ri] = p;
        ri = (ri + 1 == c->depth) ? 0 : ri + 1;
        if (old) {
            if (c->xfrac && (int)((r >> 32) % 100) < c->xfrac) {
                c->batch[c->nbatch++] = old;
                c->remote_frees++;
                if (c->nbatch == BATCH) {
                    /* Prefer WAITING over falling back to a LOCAL free: the
                     * fallback silently lowers the achieved cross-CPU fraction,
                     * the one parameter the arms must match (it measured 40%
                     * when 100% was requested).  Drain my own inbox while
                     * waiting so the producer cycle i -> i+1 cannot wedge.
                     * The wait is BOUNDED: past the bound, free locally and let
                     * `xach` report the truth, because a livelocked spin would
                     * charge spin time into the per-pair cost. */
                    int spins = 0;
                    while (!publish(c)) {
                        c->ring_full++;
                        c->drained += (uint64_t)drain_some(c);
                        if (++spins >= 256) {
                            for (int k = 0; k < c->nbatch; k++) free(c->batch[k]);
                            c->remote_frees -= (uint64_t)c->nbatch;
                            c->local_frees  += (uint64_t)c->nbatch;
                            c->nbatch = 0;
                            break;
                        }
                        if ((spins & 63) == 0) sched_yield();
                    }
                }
            } else {
                free(old);
                c->local_frees++;
            }
        }
        if (c->xfrac) c->drained += (uint64_t)drain_some(c);
    }
    c->cpu_main = cpu_s() - c0;

    /* COOPERATIVE DRAIN.  A thread that finished and stopped consuming would
     * stall its partner's ring and force the partner's remote frees to revert to
     * LOCAL ones -- silently changing the very fraction under test.  So keep
     * freeing for the partner until all threads have finished their fixed work.
     * CPU is charged ONLY around actual freeing, never around the idle spin, so
     * waiting cannot inflate the reported per-pair cost. */
    if (c->xfrac && c->nthr > 1) {
        __atomic_add_fetch(&g_done, 1, __ATOMIC_ACQ_REL);
        for (;;) {
            int all_done = (int)__atomic_load_n(&g_done, __ATOMIC_ACQUIRE) >= c->nthr;
            if (inbox_nonempty(c)) {
                double a = cpu_s();
                c->drained += (uint64_t)drain_some(c);
                c->cpu_coop += cpu_s() - a;
            } else if (all_done) {
                break;
            } else {
                sched_yield();
            }
        }
    }
    c->cpu_s  = c->cpu_main + c->cpu_coop;
    c->wall_s = now_s() - w0;
    c->cpu_end = sched_getcpu();
    return NULL;
}

/* ---------------------------------------------------------------- MODE T --- */
static double run_threads(int nthr, int depth, int xfrac, uint64_t target,
                          uint64_t *allocs, uint64_t *rem, uint64_t *loc,
                          uint64_t *full, uint64_t *bytes, int *dcpu,
                          uint64_t *leak_live, double *cpusum, double *coopsum)
{
    static struct tctx c[MAXTHR];
    static struct pairq *q;
    static int qn;
    if (qn < nthr) {                 /* only as many queues as threads: RINGSL is
                                      * large, so MAXTHR queues would be GBs */
        free(q);
        q = calloc((size_t)nthr, sizeof(*q));
        if (!q) { fprintf(stderr, "FATAL pairq alloc nthr=%d\n", nthr); exit(2); }
        qn = nthr;
    }
    memset(c, 0, sizeof(c[0]) * (size_t)nthr);
    memset(q, 0, sizeof(*q) * (size_t)nthr);
    g_bar = 0; g_done = 0;
    for (int i = 0; i < nthr; i++) {
        c[i].id = i; c[i].nthr = nthr; c[i].depth = depth; c[i].xfrac = xfrac;
        c[i].target = target; c[i].pin = 1; c[i].barrier = nthr;
        c[i].rng = 0x9e3779b97f4a7c15ULL ^ ((uint64_t)i * 0x100000001b3ULL);
        c[i].inbox  = &q[i];
        c[i].outbox = &q[(i + 1) % nthr];   /* fixed partner: strict SPSC */
    }
    double t0 = now_s();
    for (int i = 0; i < nthr; i++)
        if (pthread_create(&c[i].th, NULL, worker, &c[i])) { fprintf(stderr, "FATAL pthread_create %d\n", i); exit(2); }
    for (int i = 0; i < nthr; i++) pthread_join(c[i].th, NULL);
    double wall = now_s() - t0;

    *allocs = *rem = *loc = *full = *bytes = 0; *cpusum = 0; *coopsum = 0;
    unsigned char seen[1024]; memset(seen, 0, sizeof(seen));
    int d = 0;
    uint64_t live = 0;
    for (int i = 0; i < nthr; i++) {
        *allocs += c[i].allocs; *rem += c[i].remote_frees; *loc += c[i].local_frees;
        *full += c[i].ring_full; *bytes += c[i].bytes; *cpusum += c[i].cpu_s;
        *coopsum += c[i].cpu_coop;
        int cp = c[i].cpu_end;
        if (cp >= 0 && cp < 1024 && !seen[cp]) { seen[cp] = 1; d++; }
    }
    *dcpu = d;
    for (int i = 0; i < nthr; i++) {          /* drain, so reps do not inherit */
        int n;
        while ((n = drain_one(&c[i])) != 0) live += (uint64_t)n;
        for (int k = 0; k < c[i].nbatch; k++) { free(c[i].batch[k]); live++; }
        for (int k = 0; k < c[i].depth; k++) if (c[i].ring[k]) { free(c[i].ring[k]); live++; }
        free(c[i].ring);
    }
    *leak_live = live;
    return wall;
}

/* ---------------------------------------------------------------- MODE P --- */
struct kid { uint64_t allocs; double cpu, wall; int cpuid, id; };

static double run_procs(int nproc, int depth, uint64_t target,
                        struct kid *out, int *reaped, int *forkfail)
{
    int rfd[2], sfd[2];
    if (pipe(rfd) || pipe(sfd)) { fprintf(stderr, "FATAL pipe\n"); exit(2); }
    *forkfail = 0;
    int forked = 0;
    for (int i = 0; i < nproc; i++) {
        pid_t p = fork();
        if (p == 0) {
            close(rfd[0]); close(sfd[1]);
            static struct tctx c;
            static struct pairq qq;
            memset(&c, 0, sizeof(c));
            memset(&qq, 0, sizeof(qq));
            c.id = 0; c.nthr = 1; c.depth = depth; c.xfrac = 0;
            c.target = target; c.pin = 0;
            c.inbox = &qq; c.outbox = &qq;
            c.rng = 0x9e3779b97f4a7c15ULL ^ ((uint64_t)i * 0x100000001b3ULL);
            pin_to(i);
            /* Claim this process's allocator slot BEFORE the next child is
             * forked, so child index == slot index.  This is the assumption the
             * slope test rests on, made explicit. */
            void *claim = malloc(64);
            if (claim) free(claim);
            char go;                       /* START BARRIER: no fork stagger */
            ssize_t rr = read(sfd[0], &go, 1);
            (void)rr;
            worker(&c);
            struct kid k = { c.allocs, c.cpu_s, c.wall_s, c.cpu_end, i };
            ssize_t w = write(rfd[1], &k, sizeof(k));
            (void)w;
            _exit(0);
        }
        if (p < 0) { (*forkfail)++; continue; }
        forked++;
    }
    close(rfd[1]); close(sfd[0]);
    double t0 = now_s();
    for (int i = 0; i < forked; i++) {
        char go = 'g';
        ssize_t w = write(sfd[1], &go, 1);
        (void)w;
    }
    close(sfd[1]);

    *reaped = 0;
    struct kid k;
    size_t got = 0;
    char *b = (char *)&k;
    for (;;) {
        ssize_t r = read(rfd[0], b + got, sizeof(k) - got);
        if (r <= 0) break;
        got += (size_t)r;
        if (got == sizeof(k)) {
            if (*reaped < MAXKID) out[*reaped] = k;
            (*reaped)++;
            got = 0;
        }
    }
    close(rfd[0]);
    int st;
    while (waitpid(-1, &st, 0) > 0) { }
    return now_s() - t0;
}

/* least-squares fit of per-child CPU-ns/pair against child (== slot) index */
static void slope_of(struct kid *k, int n, double *slope, double *icept,
                     double *r2, double *mean)
{
    double sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
    int m = 0;
    for (int i = 0; i < n; i++) {
        if (!k[i].allocs) continue;
        double x = (double)k[i].id;
        double y = k[i].cpu * 1e9 / (double)k[i].allocs;
        sx += x; sy += y; sxx += x * x; sxy += x * y; syy += y * y;
        m++;
    }
    if (m < 2) { *slope = *icept = *r2 = 0; *mean = m ? sy : 0; return; }
    double d = (double)m * sxx - sx * sx;
    *slope = d != 0 ? ((double)m * sxy - sx * sy) / d : 0;
    *icept = (sy - *slope * sx) / (double)m;
    double num = (double)m * sxy - sx * sy;
    double den = d * ((double)m * syy - sy * sy);
    *r2 = den > 0 ? (num * num) / den : 0;
    *mean = sy / (double)m;
    return;
}

int main(int argc, char **argv)
{
    int all = 0, selfcheck = 0, reps = 5, depth = 512;
    uint64_t target = 3000000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-A")) all = 1;
        else if (!strcmp(argv[i], "-C")) selfcheck = 1;
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) target = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "-r") && i + 1 < argc) reps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-D") && i + 1 < argc) depth = atoi(argv[++i]);
    }
    long nc = sysconf(_SC_NPROCESSORS_ONLN);
    printf("BENCH_START ncpu=%ld pairs_per_worker=%llu reps=%d depth=%d batch=%d ptr=%zu\n",
           nc, (unsigned long long)target, reps, depth, BATCH, sizeof(void *));
    fflush(stdout);

    if (selfcheck) {                 /* NON-FATAL: never costs a whole run */
        int bad = 0;
        for (int x = 0; x <= 100; x += 50) {
            uint64_t a, r, l, f, b, live; int d; double cs, coop;
            double w = run_threads(4 > (int)nc ? (int)nc : 4, 64, x, 200000,
                                   &a, &r, &l, &f, &b, &d, &live, &cs, &coop);
            int ok = (a >= l + r) && (a - (l + r) <= live);
            if (!ok) bad++;
            printf("SELFCHECK xfrac=%d %s allocs=%llu loc=%llu rem=%llu live=%llu "
                   "xach=%.1f wall=%.3f cpusum=%.3f\n", x, ok ? "OK" : "FAIL",
                   (unsigned long long)a, (unsigned long long)l,
                   (unsigned long long)r, (unsigned long long)live,
                   (r + l) ? 100.0 * (double)r / (double)(r + l) : 0.0, w, cs);
        }
        printf("SELFCHECK_%s CPUCLOCK_OK=%d\n", bad ? "FAIL" : "PASS", cpuclock_ok);
        fflush(stdout);
    }
    if (!all) { printf("BENCH_DONE\n"); return 0; }

    /* ---- MODE P FIRST: the primary experiment (CPU-ns/pair vs slot index). -- */
    static struct kid kids[MAXKID];
    int PP[4] = {1, 8, 32, 128};
    for (int cfg = 0; cfg < 4; cfg++) {
        for (int rep = 1; rep <= reps; rep++) {
            int reaped = 0, ff = 0;
            double wall = run_procs(PP[cfg], depth, target, kids, &reaped, &ff);
            uint64_t tot = 0; double cpusum = 0, wmax = 0;
            int nn = reaped < MAXKID ? reaped : MAXKID;
            for (int i = 0; i < nn; i++) {
                tot += kids[i].allocs; cpusum += kids[i].cpu;
                if (kids[i].wall > wmax) wmax = kids[i].wall;
            }
            double slope, icept, r2, mean;
            slope_of(kids, nn, &slope, &icept, &r2, &mean);
            printf("RESULT mode=P rep=%d proc=%d reaped=%d forkfail=%d depth=%d "
                   "wall=%.4f kidwallmax=%.4f cpusum=%.4f allocs=%llu "
                   "cpu_nspp=%.2f wall_nspp=%.2f slope=%.4f icept=%.2f r2=%.4f\n",
                   rep, PP[cfg], reaped, ff, depth, wall, wmax, cpusum,
                   (unsigned long long)tot,
                   tot ? cpusum * 1e9 / (double)tot : 0.0,
                   tot ? wmax * 1e9 * (double)nn / (double)tot : 0.0,
                   slope, icept, r2);
            if (nn >= 8) {          /* raw binned slope, immune to my fit */
                printf("PBIN proc=%d rep=%d cpu_nspp_by_slot_bin:", PP[cfg], rep);
                int per = nn / 8;
                for (int bin = 0; bin < 8; bin++) {
                    double s = 0; int m = 0;
                    for (int i = bin * per; i < (bin + 1) * per && i < nn; i++) {
                        if (!kids[i].allocs) continue;
                        s += kids[i].cpu * 1e9 / (double)kids[i].allocs; m++;
                    }
                    printf(" %.1f", m ? s / m : 0.0);
                }
                printf("\n");
            }
            fflush(stdout);
        }
    }

    /* ---- MODE T: the brief's original mempool/spsc story (kernel side). ---- */
    /* (threads, cross-CPU free %).  thr=1 is the cleanest single-threaded
     * malloc/free point.  The matrix stops at 50%: at 100% every thread is both
     * a full-rate producer and consumer, the handoff queue saturates, and the
     * reported cost becomes queueing rather than allocation (measured: 30M
     * ring-full spins, cpu_nspp 261 vs 74 at 25%).  `xach` is the ACHIEVED
     * fraction and is the ground truth for what each rep actually ran. */
    int TT[4] = { 1, 32, 32, 32};
    int TX[4] = { 0,  0, 25, 50};
    for (int cfg = 0; cfg < 4; cfg++) {
        int nthr = TT[cfg] > (int)nc ? (int)nc : TT[cfg];
        if (nthr < 2 && TX[cfg]) continue;
        for (int rep = 1; rep <= reps; rep++) {
            uint64_t a, r, l, f, b, live; int d; double cs, coop;
            double wall = run_threads(nthr, depth, TX[cfg], target,
                                      &a, &r, &l, &f, &b, &d, &live, &cs, &coop);
            printf("RESULT mode=T rep=%d thr=%d xfrac=%d depth=%d wall=%.4f "
                   "cpusum=%.4f coop=%.4f allocs=%llu aps=%.0f cpu_nspp=%.2f "
                   "wall_nspp=%.2f xach=%.2f ringfull=%llu bytes=%llu dcpu=%d\n",
                   rep, nthr, TX[cfg], depth, wall, cs, coop, (unsigned long long)a,
                   (double)a / wall, a ? cs * 1e9 / (double)a : 0.0,
                   wall * 1e9 * (double)nthr / (double)a,
                   (r + l) ? 100.0 * (double)r / (double)(r + l) : 0.0,
                   (unsigned long long)f, (unsigned long long)b, d);
            fflush(stdout);
        }
    }
    printf("BENCH_DONE CPUCLOCK_OK=%d\n", cpuclock_ok);
    fflush(stdout);
    return 0;
}
