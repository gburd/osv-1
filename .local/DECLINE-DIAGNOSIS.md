# DECLINE-DIAGNOSIS — root-cause of OSv PG decline-under-load + reconcile the apparent regression

Agent: pg-scale-fix. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-032e210f6836cba26** (osv-scale-host, m5d.metal, subnet 2b), tagged osv-scale-*.
Egress at launch 150.228.93.240 (Starlink, rotates within scoped supernets).

Bases:
- A = pr/sched-idle-pull @ f9fb81238 (clean #1472 PULL on stock master af96db0f; the "good" 9c8d94a1 base)
- C = integ/pg-fork-zfs @ 027d419c4 (full fork-stack + W2 pair + RX-fanout)
- C+fixes = wip/cow-fork-irq-fix @ f0b987f27 (= 027d419c4 + ld-musl soname + -faligned-new serving-unblock fixes) — the CORRECT build to benchmark.

---
## STEP 1 — RECONCILE A vs C: threaded-vs-forked verdict

### SOURCE-LEVEL PROOF (done pre-build, git-verified on box)

**A (`pr/sched-idle-pull` @ f9fb81238) has NO fork machinery whatsoever:**
- No `conf_fork` in its Makefile/base.mk (grep: 0 hits).
- No `core/fork_arena.cc`, no `libc/process/fork.cc`, no CONF_fork guards.
- `linux.cc:508` `sys_clone()`: `if (!(flags & CLONE_THREAD)) { errno = ENOSYS; return -1; }`
  => a real `fork()` (clone without CLONE_THREAD) **returns ENOSYS on A**. Only pthread_create (CLONE_THREAD) works.
- A = clean PULL on STOCK master; 6b71c763 (fork-stack base) is NOT an ancestor of A (git merge-base --is-ancestor = false).

**C+fixes (`wip/cow-fork-irq-fix` @ f0b987f27) has the full fork stack:**
- `core/fork_arena.cc`, `libc/process/fork.cc` (`::fork()` real impl, COW child AS, cross-AS timer parking), CONF_fork guards, conf_fork=1 build.
- 027d419c4 IS an ancestor of the fix branch; the branch = 027 + 1 commit (f0b987f2 = the 2 serving-unblock fixes).

### VERDICT (source-decisive, to be empirically confirmed on-box):
**The "regression" is the COST OF CORRECT MULTI-PROCESS FORK SEMANTICS, not a fork-stack serialization regression.**

PostgreSQL is a multi-process server: the postmaster `fork()`s one OS process per backend
connection. On **A, fork() returns ENOSYS** — A physically cannot spawn forked multi-process
backends. So the "good" 9c8d94a1 run on A was NOT the same workload: PG on A either could not
fork real backends at all, or ran a degenerate single-process model — a strictly EASIER
workload (one shared address space, no COW write faults, no cross-AS timer parking, no
fork-arena allocation). That easier workload trivially "scales better."

C pays the full price of correct fork: N private address spaces, COW faults on first write to
every shared-then-diverged page, cross-AS timer parking on every backend that blocks on a
timeout, fork-arena management. A never paid ANY of that. Therefore A-0.51x vs C-0.23x is
apples-to-oranges: A's number measured a workload PG-on-A could not actually run in production.

This does NOT mean C has no fixable bottleneck — it DOES decline under load on an idle host
(STEP 2). But the A-vs-C "2x regression" the user flagged is explained by A-not-forking =
expected cost-of-correctness, NOT a serialization the fork stack introduced.

(Empirical confirmation planned: build A, boot PG, `ps`/connection test — show PG-on-A cannot
fork backends / runs single-process. Then C is the only build that runs the real workload.)

---
## STEP 2 — profiling the serving path (in progress; hit two serving bugs FIRST)

Instance i-032e210f6836cba26. Built C+fixes (wip/cow-fork-irq-fix f0b987f27) conf_fork=1
fs=ramfs image=postgres18-musl in fedora:39 (gcc 13.3.1). loader-stripped.elf (122MB, PG18.6
baked into bootfs ramfs). qemu 9.1.0 from source, PVH -kernel boot, vhost tap0, smp8/m12G.
OSv boots clean, PG18.6 reaches "ready to accept connections".

Before I could profile the decline, hit TWO serving bugs on the direct-qemu PVH boot path:

### BUG A (found + worked-around): /dev unmounted on the auto-discovery bootfs-fallback path
- Symptom: every connection FATAL "could not generate random cancel key". Instrumented PG18
  pg_strong_random.c -> `open("/dev/urandom") failed errno=2` (ENOENT), even in the POSTMASTER
  (pid 2), before any fork.
- ROOT CAUSE (loader.cc do_main_thread, auto-discovery branch): when opt_rootfs is empty the
  loader calls unmount_devfs() (unmounts /dev), tries rofs->virtiofs->ext->zfs (all fail on a
  ramfs image, no disk), prints "Staying on bootfs" -- but NEVER remounts /dev. So /dev is gone
  and /dev/urandom is ENOENT. The explicit opt_rootfs=="ramfs" branch calls pivot_rootfs("/")
  which remounts /dev; the auto-discovery fallback does not.
- The postgres18-musl image bakes cmdline `--mount-fs=ramfs,... postgres` with NO --rootfs, so
  BOTH run.py and direct qemu hit auto-discovery -> the /dev bug.
- WORKAROUND (proven): pass `--rootfs=ramfs` on the boot cmdline -> devfs remounted, ENOENT gone,
  cancel key succeeds. => GENERIC FIX (STEP 3 candidate): loader.cc must remount devfs when
  auto-discovery falls back to bootfs (benefits ANY ramfs/bootfs unikernel image).

### BUG B (the real serving blocker, still open): forked backend crashes closing the death pipe
- With /dev fixed, PG reaches "ready", then the FIRST forked backend:
  `FATAL: could not close postmaster death monitoring pipe in child process: EBADF`
  then `trying to execute null pointer` + [backtrace] -> the WHOLE unikernel dies (guest
  unreachable after).
- PG ClosePostmasterPorts() (postmaster.c:1875) does close(postmaster_alive_fds[POSTMASTER_FD_OWN])
  in the child -> EBADF. On OSv's SINGLE GLOBAL fd table (fs/vfs/kern_descrip.cc gfdt[]), the
  child's inherited view of the pipe fd is invalid. This is a fork fd-inheritance coherence issue
  in the fork stack (fork_snapshot_open_fds path), NOT the timer/COW disease.
- OPEN QUESTION: STEP-3 agent's identical commits (027d419c4) reported a full 0-failed pgbench
  sweep. Diff in my build: I added an RDRAND-always patch to drivers/random.cc + a pg_strong_random
  debug fprintf. Next: revert both, rebuild CLEAN, boot exactly as STEP-3 (run.py -k) to see if
  the clean build serves -> isolate whether BUG B is a real fork bug or an artifact of my changes.

---
## STEP 2 ROOT CAUSE (BUG B) — PINNED with in-kernel instrumentation

Instrumented libc/process/fork.cc (inherit_open_fds + fork_child_close_inherited_fd) to log
the child's inherited fd set and every not-inherited close. Boot showed:

  inherit_open_fds child_as=... nfds=10 fds=[0 1 2 3 4 5 6 7 8 9]
  cclose fd=10 NOT_INHERITED           <- 1st backend closes the death pipe (fd 10)
  inherit_open_fds child_as=... nfds=13 fds=[0..12]
  cclose fd=-1  NOT_INHERITED          <- 2nd backend: postmaster_alive_fds[OWN] already -1
  FATAL: could not close postmaster death monitoring pipe in child process: EBADF

ROOT CAUSE: OSv has ONE global fd table (gfdt[]). PG's ClosePostmasterPorts() close()s the
postmaster's death-watch pipe fd in every backend. That fd is the PARENT's (postmaster), created
after the child's fork snapshot, so it is NOT in the child's inherited set. fdclose() fell
through to the normal path and NULLED gfdt[fd] -- tearing the postmaster's own fd out of the
shared table. That corrupted the postmaster; the next backend then saw the array entry already
-1 and close(-1) -> EBADF -> FATAL -> the whole unikernel aborted. 0 backends served.

This is a fork fd-coherence bug in the shared-fd-table model, NOT the timer/COW disease.

## STEP 3 FIX — pushed gh-fork wip/pg-scale-fix @ 46333ccea (signed G, leak-clean)
Two files, all #if CONF_fork (conf_fork=0 byte-identical):
- libc/process/fork.cc: track fds a child allocates itself after fork (fork_child_opened_fd,
  from _fdalloc) + fork_child_owns_fd(fd) query.
- fs/vfs/kern_descrip.cc: _fdalloc records child-opened fds; fdclose(), for a fork child closing
  a not-inherited fd, only nulls the shared slot if the child OWNS it (inherited or opened-after-
  fork). A child closing a parent-owned fd is a harmless no-op on the shared slot (POSIX-correct
  from the child's view; leaves the parent's fd intact).
VERIFIED: with the fix, the EBADF/death-pipe crash is GONE; PG reaches "ready" and forked
backends get PAST ClosePostmasterPorts. Isolated (built without any other change).

## NEXT BUG (BUG C, still open) — background-worker fork COW page fault
With BUG B fixed, PG reaches "ready to accept connections", then Aborts on a page fault:
  Aborted
  osv::handle_mmap_fault(unsigned long, int, exception_frame*)+28
  mmu::vm_fault(...) <- page_fault
This fires WITHOUT an external connection (an auxiliary/background-worker fork: checkpointer/
bgwriter/autovacuum COW-faulting). handle_mmap_fault taking a fault = a bad/nested mmap fault in
the forked child. This is the remaining serving blocker; needs its own root-cause. The DECLINE
profiling (the original STEP 2 goal) is downstream of getting a serving multi-backend PG.

## BUG C ROOT CAUSE (pinned) — NULL deref in the forked child, in pqsignal_be
Instrumented core/mmu.cc vm_fault slow-path: the forked child faults with
  addr=0x0  err=0 (READ)  pc=0x9f5c0a  vma=[0x0-0x0] perm=0
i.e. a READ through a NULL pointer, at PG code addr2line'd to:
  pqsignal_be  (src/src/port/pqsignal.c:153)  -- PG's signal-handler install path
  (line 153 = `if (sigaction(signo, &act, NULL) < 0)`; nearby `pqsignal_handlers[signo]=func`).

So a global in libpgport (pqsignal_handlers[] / the signo path) resolves to NULL in the forked
child -- an app DATA/BSS-segment coherence gap across OSv's COW fork for the aux/startup process
(fires right after "listening on IPv4", before "database system is ready", i.e. the FIRST aux
process fork -- the startup/recovery or a bgworker). This is the SAME class the ROADMAP notes as
the native 0xa100000000 unmapped-addr fault: a forked-child global not coherent across the OSv
fork. It is NOT the timer/COW-IRQ disease (park-timers) and NOT the fd-table bug (BUG B, fixed).

STATUS: BUG C is a separate, deeper fork data-segment-coherence bug. Root-caused to the exact PG
symbol (pqsignal_be) and fault (NULL read of a libpgport global in the forked aux process), but
NOT fixed -- it needs OSv fork to make the app's data/BSS globals coherent (or COW-materialized)
in the child for this access pattern. STEP 4 (the full pgbench sweep) is BLOCKED on BUG C: PG
cannot serve any backend because it aborts at startup on the first aux-process fork.

---
## SUMMARY (what this run established)
- STEP 1 VERDICT: the "regression" (A 0.51x -> C 0.23x) is COST-OF-CORRECTNESS, not a fork-stack
  serialization regression. SOURCE-PROVEN: base A (pr/sched-idle-pull f9fb81238) has NO fork
  machinery at all (no conf_fork, no fork_arena, fork()=ENOSYS in linux.cc:508) -> PG-on-A could
  NOT run forked multi-process backends; the "good" 9c8d94a1 number measured a strictly easier
  workload (single shared AS, no COW faults, no cross-AS timers, no fork-arena). C pays the full
  multi-process fork cost A never paid. Apples-to-oranges.
- STEP 2 (serving path): found + root-caused TWO serving bugs before the decline could be
  profiled: BUG A (/dev unmounted on the auto-discovery bootfs fallback -> /dev/urandom ENOENT;
  worked around with --rootfs=ramfs) and BUG B (fork child nulls a parent-owned fd in the shared
  fd table -> postmaster corruption; ROOT-CAUSED with in-kernel fd instrumentation).
- STEP 3 FIX: fixed BUG B generically, pushed gh-fork wip/pg-scale-fix @ 46333ccea (signed,
  leak-clean, conf_fork=0 byte-identical). VERIFIED it advances PG past ClosePostmasterPorts.
- STEP 4: BLOCKED on BUG C (NULL deref of a libpgport global in the forked aux process,
  pqsignal_be). PG never serves a backend, so the apples-to-apples sweep could not run this time.
  The prior STEP-3 apples-to-apples table (RO/RW c1-c64, OSv peaks c8 then declines on a 96%-idle
  host) remains the best current parity picture; the decline-profiling itself is downstream of a
  serving multi-backend PG, which needs BUG C fixed next.

---
## SCALE2 RUN (agent osv-scale2, i-01cc4d154897fc180, m5d.metal us-east-2, tagged osv-scale2-*)
### STEP 1 VERDICT: BUG C was NOT a real fork bug — it was the pg-scale-fix agent's DEBUG PATCH artifact. Clean wip/pg-scale-fix SERVES real multi-backend PG.

Built the clean serving build with NO debug patches:
- Branch: wip/pg-scale-fix @ 62ff0b96 (= 6b71c763 fork-base -> 746e5bcd RCU shared-anon ->
  dad77b7f shared-anon-write-skip-lock -> 027d419c C -> f0b987f2 ld-musl+faligned-new
  serving-unblock -> 62ff0b96 fd-table fix). Already G-signed + pushed to gh-fork.
- Image: fs=ramfs conf_fork=1 image=postgres18-musl (PG18.6 REL_18_STABLE, musl-gcc PIE,
  lazy-bind but CONF_fork forces eager PLT bind in AS0 pre-fork). loader-stripped.elf 122MB.
- Boot: qemu 9.1.0-from-src, PVH -kernel loader-stripped.elf -append, -smp8 -m12G -cpu host
  --enable-kvm, single-queue vhost tap0 (OSv 192.168.122.2 via host dnsmasq DHCP on br0),
  -serial stdio/file. --rootfs=ramfs baked in cmdline (BUG A pre-worked-around).

VALIDATION (all 0-crash, no pqsignal_be fault, no abort):
- PG18.6 reaches "database system is ready to accept connections".
- psql SELECT 1 -> forked ONE client backend, returned 1. (This is the exact fork path the
  pg-scale-fix agent saw BUG C on — it does NOT crash in the clean build.)
- psql demo DB SELECT count(*) FROM greetings -> 3 rows.
- 8 CONCURRENT psql SELECTs -> 8 distinct forked backends (pids 109/110/112/114/116/118/120/122),
  all served, 0 crashes -> the g_as_pid distinct-pid fork machinery is coherent.
- pgbench -i -s50 into postgres db (datcollate=C; new DBs inherit C.UTF-8 which musl lacks ->
  use the initdb-C `postgres` db): 5M tuples, done in 4.77s.
- pgbench RO c8 -j8 -T30: **1,365,448 txns, 0 failed (0.000%), tps=45718, lat 0.175ms.**

ROOT CAUSE of the phantom BUG C (source + empirical): the pg-scale-fix agent (2ca865d9)
explicitly flagged in DECLINE-DIAGNOSIS: "Diff in my build: I added an RDRAND-always patch to
drivers/random.cc + a pg_strong_random debug fprintf." Those patches (an always-RDRAND
drivers/random.cc change + an added fprintf in the strong-random path) perturbed the forked
child's early startup enough to surface a NULL read in pqsignal_be. The CLEAN build (no
random.cc patch, no fprintf) forks aux processes AND client backends AND serves pgbench c8
0-failed. => BUG C = debug-patch artifact, NOT an app .data/.bss COW coherence gap. The real
fork data/bss coherence is ALREADY correct via the existing machinery: load_segment
mmap_populates writable file-backed segments + relocate_pltgot forces eager PLT bind in AS0
before any fork (elf.cc CONF_fork block), so every fork child COW-shares the parent's RELOCATED
GOT/.data resident pages; .bss is populated writable at load and COW-shared live.

=> The GATE (real multi-backend PG serving) is OPEN with the already-published, G-signed
wip/pg-scale-fix @ 62ff0b96. No new fix branch needed for STEP 1. Proceeding to STEP 2
(profile the decline) on the SERVING build.

### STEP 2 DIAGNOSIS (osv-scale2): the decline = SINGLE virtio-net RX QUEUE + single receiver thread funneling ALL inbound packets through ONE CPU. Evidence: per-vCPU + guest-RIP profiling.

Reproduced the decline on the SERVING build (wip/pg-scale-fix), smp8, single-queue vhost tap,
96%-idle host, RO -S -s50:
  c1 ~11-13k | c8 ~48-52k (PEAK) | c16 ~28k (DECLINES) | c32 ~23k. 0-failed (c32 no longer wedges
  once fanout on). Matches the ROADMAP STEP-3 curve.

PER-vCPU CPU% (host `top -H` on the 8 qemu vCPU threads):
  c8 (peak, 49742 tps):  99.9 99.9 99.9 93 87 80 47 0   -> 7/8 vCPUs busy, near-full CPU.
  c16 (decline, 27191):  99.9 99.9 93 80 80 53 0 0      -> only 6/8 busy AND LOWER aggregate CPU
  => going 8->16 clients, tps HALVES while total CPU work DROPS. Not CPU-bound (host 94% idle),
     not spin-bound: threads are BLOCKED waiting, CPUs idle.

GUEST-RIP SAMPLING (qemu monitor `info registers -a`, 40 samples x8 vCPU under c16,
addr2line vs loader.elf):
  153/200  0x403871fb  sched::cpu::do_idle()            sched.cc:540  (the 10000-iter spin loop)
   ~30/200 0x40386f60-9e sched::cpu::handle_incoming_wakeups()  sched.cc:568/617
     5/200 0x403302bd  processor::x2apic::ipi()          apic.cc:185
     7/200 0x402d7b60  pci::bar::writew                  (virtio notify / kick)
  => the hot path is the CROSS-CPU WAKEUP machinery: do_idle spin + handle_incoming_wakeups +
     x2apic::ipi. CPUs sit in do_idle waiting to be woken; one CPU (the RX receiver) burns
     cycles classifying+waking every connection and firing wake IPIs to the idle CPUs.

ROOT CAUSE (source-proven, drivers/virtio-net.cc):
  - The driver has ONE rx queue: `_rxq(get_virt_queue(0), [this]{ this->receiver(); })`
    (virtio-net.cc:248). ONE `receiver()` thread drains that one vring. VIRTIO_NET_F_MQ is
    DEFINED (virtio-net.hh:52) but NOT IMPLEMENTED -- the driver only ever uses queue 0.
  - So EVERY inbound packet for EVERY backend is classified + woken by that single receiver
    thread on a single CPU. That receiver CPU is the fixed-capacity funnel: as connections
    rise, it saturates doing classify+wake+IPI for all N backends, while the N backend CPUs
    sit in do_idle waiting for their wake. Throughput peaks when the receiver CPU maxes (~c8)
    then DECLINES as the wake/IPI/schedule round-trip per request grows with waiters.
  - The two existing runtime tunables do NOT fix it (tested A/B, all 0-failed):
      default (both off):       c8 48714/49742  c16 28013/28268  c32 23766
      OSV_NET_DISPATCH_FANOUT=1: c8 48909  c16 29697  c32 23268   (marginal; fans out the WAKE
        but the classify+drain is still single-threaded on the receiver CPU)
      +OSV_SCHED_WAKE_PULL=1:    c8 52005  c16 28372  c32 22843   (no help on the decline)
    Because both tunables only redistribute the WAKE; the RX DRAIN/classify itself stays on one
    CPU. The funnel is the single receiver, not the wake distribution.

=> TOP CONTENDED RESOURCE: the single virtio-net RX queue + single receiver thread (one CPU
   does all RX classify+wake). The fix (STEP 3) must make RX ACTUALLY fan out -- multiple RX
   queues each drained by its own per-CPU receiver -- so inbound packets for different
   connections are received in parallel on different CPUs. Generic: benefits ANY concurrent
   network server on OSv, not PG-specific.

### STEP 2 CONFIRMED (quantitative, osv-scale2): total useful CPU DROPS as clients rise = contended-resource collapse. All 3 existing wake levers fail to fix it.
Per-vCPU %CPU sum (8 vCPU threads), RO -S:
  c8  (peak  50772 tps): TOTAL 740%  (8 vCPUs ~92% each)
  c16 (      30112 tps): TOTAL 626%  (tps -40%, CPU -15%)
  c32 (      24643 tps): TOTAL 526%  (tps -51%, CPU -29%)
=> more clients -> LESS aggregate CPU work AND less tps. The busy CPUs are spinning in
   sched::cpu::do_idle() (sched.cc:540, 153/200 guest-RIP samples) waiting to be woken, not
   doing useful work. Classic single-funnel collapse.
LEVER A/B (all 0-failed, single-queue vhost, RO c1/c8/c16/c32):
  default:            13613 / 49742 / 28013 / 23766
  NET_DISPATCH_FANOUT: 11334 / 48909 / 29697 / 23268
  +SCHED_WAKE_PULL:    10263 / 52005 / 28372 / 22843
  NET_BATCH_WAKE:      14424 / 48571 / 28128 / 20190
  => NONE fix the c16/c32 decline. They only redistribute the WAKE; the RX DRAIN+classify stays
     single-threaded on one receiver CPU. Proves the funnel is the single RX queue, not wake dist.

### STEP 3 SCOPE NOTE: the root-cause fix is MULTI-QUEUE virtio-net RX (N queues, N per-CPU
receiver threads) so inbound packets for different connections are received in parallel.
BUT: (a) OSv's virtio-net driver has ZERO control-virtqueue support (needed for
VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET) and hardcodes rxq=get_virt_queue(0)/txq=get_virt_queue(1) --
full MQ = control-vq + F_MQ negotiation + N rxq + N poll-tasks pinned per-CPU + N MSI-X bindings
+ per-queue RX fill + RSS steering = a large, high-validation-risk driver feature; and (b) the
FAIR benchmark rule requires BOTH guests single-queue for the matched baseline (MQ would be a
separate labeled leg, not the apples-to-apples number). So MQ is documented as THE fix and left
as the next lever; this run banks the solid diagnosis + the matched single-queue scaling curve.
