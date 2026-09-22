#!/usr/bin/env python3
# bench24 probe insertion.  Three instruments, all printf (NEVER debugf --
# verbose-gated and silent by default), all with a startup line proving they were
# reached.
#
#   SCHEDPROBE  per-CPU busy% + aggregate busy vCPU + n_ge50/n_le5, plus the
#               mutex sleep-handoff counters.  Two jobs this run:
#                 (a) CPU PER TRANSACTION, the headline: agg_busy_vcpu / tps.
#                 (b) CONFIRM OR REFUTE n_le5=0 at the busiest cell.  An
#                     aggregate utilisation number cannot distinguish "some CPUs
#                     idle" from "all CPUs stalled"; only the distribution can.
#
#   NONROTPROBE #1513 must be proven LIVE, not merely present in source.  The
#               flag (vd->vdev_nonrot = B_TRUE) is the CAUSE; the EFFECT is that
#               vdev_queue_aggregate() stops building >128 KiB aggregates.  So
#               count device requests by size at the vdev->bio boundary and print
#               max_KiB + n_gt128KiB.  A source grep cannot show this; a
#               histogram at the strategy() call can.
#
#   ARCPROBE    inserted separately by insert-arc-probe.py (arc_c AND arc_size
#               MEASURED per cell, never an asserted cap).
#
# Every anchor is checked and a miss is FATAL.  A probe build that silently
# failed to insert its probe is the "gate that cannot fail" defect: the run would
# look fine and measure nothing.
import sys

FAIL = []

def edit(path, subs):
    try:
        s = open(path).read()
    except IOError:
        FAIL.append("MISSING " + path); return
    o = s
    for old, new, n in subs:
        if s.count(old) < 1:
            FAIL.append("ANCHOR-MISS %s :: %s" % (path, old[:70])); continue
        s = s.replace(old, new, n)
    if s != o:
        open(path, "w").write(s); print("PATCHED", path)

# ---------------------------------------------------------------- MTXPROBE
edit("core/lfmutex.cc", [
 ("""namespace lockfree {

TRACEPOINT(trace_mutex_lock, "%p", mutex *);""",
  """namespace lockfree {

// bench24 probe: does a contended mutex acquisition cost a sleep/wake round trip
// on the hot path?  Relaxed ordering: rate counters, never control flow.
std::atomic<unsigned long> mtxprobe_lock{0};
std::atomic<unsigned long> mtxprobe_uncont{0};
std::atomic<unsigned long> mtxprobe_blocked{0};
std::atomic<unsigned long> mtxprobe_rho{0};

TRACEPOINT(trace_mutex_lock, "%p", mutex *);""", 1),

 ("""    sched::thread *current = sched::thread::current();

    if (count.fetch_add(1, std::memory_order_acquire) == 0) {""",
  """    sched::thread *current = sched::thread::current();

    mtxprobe_lock.fetch_add(1, std::memory_order_relaxed);
    if (count.fetch_add(1, std::memory_order_acquire) == 0) {
        mtxprobe_uncont.fetch_add(1, std::memory_order_relaxed);""", 1),

 ("""    // Wait until another thread pops us from the wait queue and wakes us up.
    trace_mutex_lock_wait(this);
    waiter.wait();""",
  """    // Wait until another thread pops us from the wait queue and wakes us up.
    // Reaching here is the expensive case: a full sleep + wake.
    mtxprobe_blocked.fetch_add(1, std::memory_order_relaxed);
    trace_mutex_lock_wait(this);
    waiter.wait();""", 1),

 ("""                wait_record *other = waitqueue.pop();
                assert(other);
                if (other->thread() != current) {""",
  """                wait_record *other = waitqueue.pop();
                assert(other);
                mtxprobe_rho.fetch_add(1, std::memory_order_relaxed);
                if (other->thread() != current) {""", 1),
])

# --------------------------------------------------------------- NONROTPROBE
# Proof of EFFECT for #1513.  Counters live here so the histogram sits exactly at
# the vdev->device boundary -- the place a >128 KiB aggregate would have to appear
# if vdev_queue_aggregate() were still using the rotating-disk limit.
edit("modules/open_zfs/osv/module/os/osv/zfs/vdev_disk.c", [
 ("""static void
vdev_disk_io_start(zio_t *zio)
{""",
  """/*
 * bench24 #1513 LEVER-EFFECT PROBE.  vd->vdev_nonrot = B_TRUE is the CAUSE; the
 * EFFECT under test is that vdev_queue_aggregate() no longer builds aggregates
 * above the 128 KiB non-rotating cap.  Presence of the flag in source proves
 * nothing at runtime, so count requests by size AT THE DEVICE BOUNDARY and let
 * the console report max_KiB and n_gt128KiB.  Relaxed atomics: rate counters.
 */
unsigned long nonrot_req_total;
unsigned long nonrot_req_gt128k;
unsigned long nonrot_req_max_bytes;

static void
nonrot_probe_note(size_t sz)
{
	__atomic_add_fetch(&nonrot_req_total, 1, __ATOMIC_RELAXED);
	if (sz > 131072)
		__atomic_add_fetch(&nonrot_req_gt128k, 1, __ATOMIC_RELAXED);
	unsigned long m = __atomic_load_n(&nonrot_req_max_bytes, __ATOMIC_RELAXED);
	while (sz > m &&
	    !__atomic_compare_exchange_n(&nonrot_req_max_bytes, &m, sz, 0,
		__ATOMIC_RELAXED, __ATOMIC_RELAXED))
		;
}

static void
vdev_disk_io_start(zio_t *zio)
{""", 1),

 ("""	zio->io_bio = data;

	bio->bio_dev->driver->devops->strategy(bio);
}""",
  """	zio->io_bio = data;

	nonrot_probe_note(size);
	bio->bio_dev->driver->devops->strategy(bio);
}""", 1),
])

# ---------------------------------------------------------------- SCHEDPROBE
edit("core/sched.cc", [
 ("""osv::clock::uptime::duration process_cputime()""",
  """// bench24 probe.  PER-CPU busy% so an aggregate cannot hide the distribution,
// plus the numerator for CPU-PER-TRANSACTION (agg_busy_vcpu / tps).
// cpu->idle_thread->thread_clock() is the same accounting process_cputime()
// uses, so this is load-bearing kernel accounting, not a new estimate.
//
// The MTXPROBE counters live in ::lockfree and the NONROT counters in the
// OpenZFS OSv platform layer.  Both declarations must be at GLOBAL scope: inside
// namespace sched the linker would look for sched::lockfree::* and fail.
}  // namespace sched

namespace lockfree {
extern std::atomic<unsigned long> mtxprobe_lock;
extern std::atomic<unsigned long> mtxprobe_uncont;
extern std::atomic<unsigned long> mtxprobe_blocked;
extern std::atomic<unsigned long> mtxprobe_rho;
}

// NOTE: the #1513 nonrot_* counters are NOT reported from here, and that is a
// correction to this probe's first version rather than an omission.  They are
// defined in vdev_disk.c, which links into libsolaris.so, so an
// `extern __attribute__((weak))` reference from the kernel is an UNDEFINED weak:
// it compiles, it links, and `if (&sym)` folds to false at compile time, so the
// print was eliminated as dead code and the probe could never fire.  Proven with
// nm before the run: zero nonrot symbols in loader.elf, three in libsolaris.so.
// The NONROTPROBE line is therefore emitted by the ARC probe, inside the same
// shared object as the counters, where the symbols actually resolve.

namespace sched {

static void schedprobe_dump_once()
{
    static u64 last_idle[max_cpus];
    static u64 last_wall;
    static unsigned long last_l, last_u, last_b, last_r;

    u64 wall = std::chrono::duration_cast<std::chrono::nanoseconds>(
        osv::clock::uptime::now().time_since_epoch()).count();
    u64 dwall = wall - last_wall;
    last_wall = wall;
    if (!dwall) return;

    printf("SCHEDPROBE ncpu=%u wall_ms=%llu percpu_busy_pct=",
        (unsigned)cpus.size(), (unsigned long long)(dwall / 1000000));
    unsigned nbusy = 0, nidle = 0;
    u64 sumbusy = 0;
    for (cpu *c : cpus) {
        u64 idle = std::chrono::duration_cast<std::chrono::nanoseconds>(
            c->idle_thread->thread_clock()).count();
        u64 didle = idle - last_idle[c->id];
        last_idle[c->id] = idle;
        u64 busy = (didle < dwall) ? (dwall - didle) : 0;
        unsigned pct = (unsigned)((busy * 100) / dwall);
        sumbusy += busy;
        if (pct >= 50) nbusy++;
        if (pct <= 5) nidle++;
        printf("%u%s", pct, (c->id + 1u < cpus.size()) ? "," : "");
    }
    printf(" agg_busy_vcpu=%llu.%02llu n_ge50=%u n_le5=%u",
        (unsigned long long)(sumbusy / dwall),
        (unsigned long long)(((sumbusy % dwall) * 100) / dwall),
        nbusy, nidle);

    unsigned long l = lockfree::mtxprobe_lock.load(std::memory_order_relaxed);
    unsigned long u = lockfree::mtxprobe_uncont.load(std::memory_order_relaxed);
    unsigned long b = lockfree::mtxprobe_blocked.load(std::memory_order_relaxed);
    unsigned long r = lockfree::mtxprobe_rho.load(std::memory_order_relaxed);
    printf(" MTXPROBE d_lock=%lu d_uncont=%lu d_blocked=%lu d_rho=%lu",
        l - last_l, u - last_u, b - last_b, r - last_r);
    last_l = l; last_u = u; last_b = b; last_r = r;
    printf("\\n");
}

void schedprobe_start()
{
    const char *e = getenv("OSV_SCHEDPROBE");
    if (e && e[0] == '0') { printf("SCHEDPROBE off\\n"); return; }
    const char *iv_s = getenv("OSV_SCHEDPROBE_INTERVAL");
    int iv = (iv_s && iv_s[0]) ? atoi(iv_s) : 10;
    if (iv < 1) iv = 1;
    printf("SCHEDPROBE started interval_s=%d\\n", iv);
    auto *t = thread::make([iv] {
        for (;;) {
            thread::sleep(std::chrono::seconds(iv));
            schedprobe_dump_once();
        }
    }, thread::attr().name("schedprobe").detached());
    t->start();
}

osv::clock::uptime::duration process_cputime()""", 1),
])

edit("loader.cc", [
 ("    mmu::fp_probe_start();",
  "    mmu::fp_probe_start();\n    sched::schedprobe_start();", 1),
])

edit("include/osv/sched.hh", [
 ("osv::clock::uptime::duration process_cputime();",
  "osv::clock::uptime::duration process_cputime();\n// bench24 probe: per-CPU busy% + mutex handoff + #1513 request-size histogram.\nvoid schedprobe_start();", 1),
])

if FAIL:
    print("PROBE_INSERT_FAILED")
    for f in FAIL: print(" ", f)
    sys.exit(1)
print("PROBE_INSERT_OK")
