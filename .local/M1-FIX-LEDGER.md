# M1 fix ledger

Consolidated bookkeeping of the M1 investigation (stock PostgreSQL on OSv+OpenZFS
vs PG/Linux under HammerDB TPROC-C, matched substrate). One line per fix: what it
fixes, the measured effect, and its status. Nothing here is editorialized beyond
what the notes measured.

Source notes: M1-THREE-OSV-OVERHEADS.md, WRITE-DEPTH-GOVERNOR-STUDY.md,
WAKEUP-FANOUT-RESULT-AND-REFRAME.md, M1-CEILING-LWB-PIPELINE-DEPTH.md,
CHECKPOINT-2026-09-15.md.

## The unifying root cause (the campaign's real deliverable)
The M1 gap is FULLY DECOMPOSED, not a mystery. Measured OSv-vs-Linux on identical
m5d.metal + raw-passthrough NVMe + matched ZFS geometry, byte-identical probes:

  WRITE:  OSv 288-372us vs Linux 140-266us  (~2x)   dominant per-lwb cost, fat tails
  DEPTH:  OSv mean ~1.5 in flight vs Linux ~13-99  (~9-14x) shallow-effective pipeline
  FLUSH:  ruled OUT as a fixable target (see refutations below)

Every layer traced to ONE root: **OSv's cross-vCPU WAKEUP LATENCY** (IPI to a
halted vCPU -> VM-exit), which is more expensive than Linux's inline/softirq wake.
It surfaces as: the wedge (dead wakes), the fan-out (serial wakes under a lock),
the completion path, and the ZIL commit RECYCLE (a flushed backend must be
rescheduled onto a CPU to re-enter as the next lwb committer). OSv and Linux run
the SAME upstream zil.c single-committer-in-caller model (no dedicated issuer);
Linux builds depth ~13-99 purely by recycling backends faster via cheap wakes.
OSv keeps ~1.5 in flight because each recycle eats a cross-vCPU wake VM-exit.
`OSV_IDLE_SPIN` attacks the WAKE half directly (idle vCPUs spin before halting,
so a woken committer catches the wake in-spin instead of via IPI/VM-exit).

## Fix table (isolate = pwrite+fdatasync storm microbenchmark; HammerDB = TPROC-C NOPM)

| Fix | PR / branch | What it fixes | Measured effect | Status |
|-----|-------------|---------------|-----------------|--------|
| dentry AB-BA deadlock | #1502 | AB-BA between dentry_hash_lock and vnode lock | e2e-proven correctness fix (deadlock) | FILED, open, clean |
| per-chain dentry lock | #1503 | global dentry hash lock -> per-chain | contention reduction | FILED, open, clean |
| TCB psABI guards | #1504 | psABI stack + pointer guards in TCB | correctness/hardening | FILED, open, clean |
| ZIL hires timeouts | #1505 | SPL cv_timedwait_hires honours sub-tick timeouts | correctness (commit-window timing input) | FILED, open, clean |
| ARC ceiling env | #1506 | OSV_ZFS_ARC_MAX explicit ARC cap for app coexistence | app-coexistence knob | FILED, open, clean |
| fsync scan skip | #1507 | skip whole-file writeback scan on fsync when clean | removes wasted scan; NOPM-null | FILED, open, clean |
| physio per-iovec | #1508 | one bio per iovec in physio() w/ correct length | correctness (extracted from #1424) | FILED, open, clean |
| virtio-blk per-queue completion | #1509 | one completion thread per virtqueue, DEFAULT-ON | isolate +33-38% op/s (t32 11.5k->23.5k = +2.1x); HammerDB NULL | FILED, open, clean, default-on |
| idle-CPU wake-pull | #1472 | disperse woken threads via idle-CPU pull, default-on | wake-dispersion; part of wake theme | FILED, open, clean |
| ext4 read-ahead | #1510 | ext4 sequential-read read-ahead + async prefetch | perf (read path); replaced CLOSED #1447 | FILED, DRAFT (needs re-measure to un-draft) |
| idle spin-before-halt | #1501 | OSV_IDLE_SPIN: idle vCPU spins before halt under sustained wakes | isolate op/s +56-140% (t8 12k->28.6k, t16 18.8k->40.3k, t32 30.7k->48k), OSv >= Linux; HammerDB UNVERIFIED | FILED, DRAFT |
| ZIL wake-unlocked (Lever-1) | bench/zil-wake-unlocked @ 1fe51340 | hoist lwb-waiter wakes out of zl_lock | zl_lock hold 52->7us (7x cut), p99/variance merit; op/s NULL (noise) | BENCH-ONLY (filed on contention merit per notes; not a throughput claim) |

## Root-cause chain, decomposed (what the isolate proved)
`OSV_IDLE_SPIN` (existing sched knob, no zil.c change, upstream-faithful) is the
one lever that CLOSES the durable-write ISOLATE gap. Mechanism = recycle SPEED,
not concurrency: lwb depth mean stayed ~1.5 on BOTH arms; the win is ~2.5x more
issues because the flush-wake -> next-committer-entry latency (wake2ent) halved
(t32 132->73us) and issue_gap dropped 303->187us. rate = depth/latency: cutting
recycle latency at constant depth raises the rate. On the isolate OSv reaches or
exceeds Linux (t16 40.3k > Linux 34.5k, t32 48k ~= Linux 45.7-48.6k).

## Refuted hypotheses (each killed by a cheap measurement before a PR/claim)
1. strict depth-1 pipeline serialization  -> REFUTED (OSv overlaps up to 6-11 lwbs)
2. issuer pacing / commit window widening  -> REFUTED (waiter wakes ~60us; widening HURTS)
3. block-completion drain parallelism (#1509) -> real +33-38% isolate, HammerDB NULL
4. wakeup fan-out under zl_lock (Lever-1)  -> real 7x zl_lock cut, throughput NULL
5. LWB flush pipeline depth ~1             -> REFUTED (depth 6-14, pipeline works)
6. flush = INTERRUPT-taskq hops (inline)   -> REFUTED (whole inline flush pipeline
   = 38.5us, ~11us irreducible lock+cv_broadcast; branch fired 100%, backing
   symmetric raw device; op/s flat-to-negative; the ~100us "flush" residual is a
   NOISY est_flush = whole - write subtraction, dominated by the WRITE portion)

## Where M1 stands (honest, per CHECKPOINT-2026-09-15)
- ISOLATE (pure durable-write concurrency): gap CLOSED by OSV_IDLE_SPIN. Real.
- HammerDB TPROC-C VERDICT: **UNVERIFIED.** Every HammerDB attempt at closing the
  gap was blocked by ZFS-pool-seed failures (seed_copy EACCES into fresh 0700 ZFS
  dirs; the 0777 workaround HUNG the guest mid-copy - a separate ZFS-write
  robustness gap). The isolate CANNOT settle whether idle-spin transfers to a
  query workload: idle-spin burns idle-vCPU cycles, which on TPROC-C could steal
  query cycles (net loss) or net-win (wake latency saved > spin cost). The final
  verdict run (OSV_IDLE_SPIN HammerDB sweep, agent-spinverdict) is IN FLIGHT.
- Do NOT read the isolate win as "M1 closed". TPROC-C transfer is the one open
  question. Deliverable regardless of the outcome: 11 real upstream PRs, a fully
  decomposed + Linux-contrasted root cause (cross-vCPU wakeup latency), and a
  validated Debian-12/native-qemu-7.2 substrate.

## Shipped vs filed vs bench-only (summary)
- FILED master-facing, merge-tree clean, non-draft: #1502 #1503 #1504 #1505 #1506
  #1507 #1508 #1509 #1472  (9)
- FILED, DRAFT (need work to un-draft): #1510 (ext4 re-measure), #1501 (OSV_IDLE_SPIN
  HammerDB verdict pending)
- BENCH-ONLY: Lever-1 zil-wake-unlocked (bench/zil-wake-unlocked); OSV_IDLE_SPIN
  also lives on the current bench line (79ed402f4). None claimed as M1 parity.
