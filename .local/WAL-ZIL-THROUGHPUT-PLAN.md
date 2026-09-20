# WAL/ZIL write-path throughput plan (OSv PG-on-ZFS)

## The measured problem
800/500wh HammerDB, both stacks I/O-bound before vCPU, bottleneck = WAL write + `LWLock:WALWrite`:
- Linux ext4: ~766 MB/s WAL -> 181K NOPM @ VU192
- Linux ZFS:  ~500-530 MB/s WAL -> ~112-127K NOPM (~40% lower than ext4)
- OSv ZFS:    ~200 MB/s reads @ ~50% util, VU96 NOPM 10.8K, declining; VU192 OOM

The ~40% ZFS-vs-ext4 gap is a ZFS-write-path story, NOT an OSv-specific defect (Linux ZFS
shows the SAME gap). But OSv's ABSOLUTE numbers are far below Linux ZFS, so there are TWO
distinct problems:
  (P1) the generic ZFS-vs-ext4 WAL gap (shared with Linux; a config/tuning story)
  (P2) OSv ZFS being far below Linux ZFS (an OSv write-path latency story)

## Root-cause research (code-confirmed, not hypothesis)
1. **Every fsync = zil_commit = one lwb write + a per-vdev `zio_flush` (BIO_FLUSH).**
   (openzfs module/zfs/zil.c: zil_lwb_write_done -> zio_flush per vdev.) So WAL throughput =
   commits/sec = 1 / (lwb-write + cache-flush + wake round-trip) latency, times the group-commit
   batch factor.
2. **OSv drivers issue REAL hardware flushes** (nvme.cc:443 NVME_CMD_FLUSH, virtio-blk
   VIRTIO_BLK_T_FLUSH) and correctly SKIP the flush when the device has no volatile write cache
   (nvme.cc:458: `vwc==0` -> biodone immediately). So flush mechanics are correct.
   >> TO MEASURE: does AWS instance-store NVMe advertise vwc? If vwc==0, the per-commit flush is a
      near-noop and the gap is elsewhere (wake latency); if vwc==1, each commit is a real device
      round-trip and coalescing/SLOG matters most.
3. **recordsize=8k on the SAME dataset for BOTH data and WAL is a known ZFS-PG anti-pattern.**
   PG WAL is a large sequential stream written in 8KB records into 16MB segments; forcing 8k ZFS
   blocks fragments the sequential WAL into tiny blocks + extra metadata + more indirect writes =
   ZFS write-amplification. WAL wants a LARGER recordsize (or its own dataset). Our benchmark pool
   uses ONE recordsize=8k dataset for everything.
4. **ZIL group-commit is timer-driven** (zfs_commit_timeout_pct=10). The earlier wall-clock cv fix
   (1dc86f42c) restored coalescing; the batch factor still depends on OSv timer + wake latency.
5. **Wake latency**: the whole campaign's recurring theme (halted vCPUs, wake round-trip). A commit
   waiter sleeps on a cv and is woken by the AS0 ZIL/zio completion thread; that cross-CPU wake is
   in the commit critical path.

## PHASE 0+1 RESULT (2026-08-29): PROFILE DECIDED - see below
MEASURED, not hypothesized:
- **NVMe vwc=0** on AWS instance-store -> per-commit BIO_FLUSH is a device no-op (0ms).
- Commit floor (4k fsync-each): ext4 17400/s, LinuxZFS 5505/s, OSv-ZFS 2840/s. P1=3.2x (generic
  upstream-ZFS penalty, not OSv-addressable), **P2=1.94x (OSv write-path latency = the lever)**.
- pg_stat_io: fsync_time~=0, write_time~=0. Per-commit cost is NEITHER flush NOR write - it is the
  **wake round-trip** to the committing backend after the ZIL lwb completes, serialized under
  LWLock:WALWrite.
- **Phase 1 config levers = NULL (~+6% best, within noise).** The recordsize split (L1 centerpiece)
  is applied correctly but cannot move a wake-bound commit rate on a vwc=0 device. Keep it documented:
  it IS the right config on a real (vwc=1) device where the flush costs a round-trip - it is a no-op
  only on this instance-store.
- **VERDICT: the gap is WAKE-BOUND. Phase 2 (the narrow ZIL-completion wake path) is the only lever
  left and is warranted. Config/SLOG (Phase 3) do not apply on vwc=0.**

## Plan: measure-first, cheapest lever first, generic-not-PG-specific

### Phase 0 - INSTRUMENT + ISOLATE (no code change; decides everything)
Establish WHERE the per-commit latency goes before touching code. On a metal box, OSv ZFS, 500wh:
- Measure vwc on the AWS NVMe (does the flush cost a real round-trip?).
- fio-style: raw QD1 O_DSYNC 8k write to the ZFS dataset -> commits/sec ceiling (the floor the WAL
  can't beat). Compare to Linux ZFS same test (isolates OSv-vs-LinuxZFS = P2) and to ext4 (P1).
- zpool iostat -r / -w during a WAL-only load: lwb write size distribution + per-op latency, and
  whether flushes dominate.
- pg_stat_wal + a wait-event histogram: WALWrite vs WalSync vs WALInsert split.
DECISION GATE: the profile picks the lever. Do NOT pre-commit to a fix.

### Phase 1 - CONFIG levers (zero OSv code; test the generic P1 gap first, cheapest)
Pure benchmark-config A/B, each measured, each a legitimate ZFS-PG tuning (NOT a PG-specific hack -
these are the standard, documented ZFS-for-PG settings):
- **Separate WAL dataset with a larger recordsize** (e.g. WAL on recordsize=64k-1M, data stays 8k).
  Directly attacks the recordsize anti-pattern (item 3). Biggest expected P1 win.
- **`logbias=throughput` for the WAL dataset** vs latency (fewer indirect ZIL writes for the
  streaming WAL).
- **PG `full_page_writes`**: ZFS is copy-on-write and atomic at recordsize, so torn-page protection
  from FPW is arguably redundant on ZFS -> `full_page_writes=off` roughly halves WAL volume. This is
  the single biggest WAL-volume lever AND it is ZFS-correctness-legitimate (ZFS gives atomic block
  writes). Measure durability carefully; document the ZFS-atomicity justification.
- **`wal_sync_method`**: confirm PG picks fdatasync/open_datasync optimally on OSv; a wrong choice
  double-flushes.
- **PG `commit_delay`/`commit_siblings`**: widen the group-commit window so more backends batch into
  one lwb+flush - the direct group-commit lever, generic PG tuning.
These answer "how much of the gap is just tuning?" with no OSv risk. Likely closes much of P1.

### Phase 2 - OSv write-path latency (P2: OSv ZFS << Linux ZFS) - only what Phase 0 points at
Whichever the profile fingers, generic OSv improvements (each measured to move commits/sec):
- **(most likely) wake latency on the ZIL completion path**: the zio/lwb completion -> cv wake of
  the commit waiter is a cross-CPU round-trip through halted vCPUs. This is the SAME lever as the
  earlier wake-local work but on the STORAGE-completion wake specifically. A targeted, narrow
  wake-local retarget for the ZIL-completion -> commit-waiter wake (the earlier broad synch/taskq
  wiring crashed; do the NARROW, storage-completion-only version, guarded like the net_channel one).
- **flush handling**: if vwc==1 and flushes dominate, ensure the NVMe flush completion isn't
  serialized behind interrupt-coalescing (already made opt-in, PR #1481) and that a flush isn't
  waiting a full IRQ-coalesce window. Consider a dedicated high-priority completion path for flushes.
- **lwb write zio dispatch**: confirm the lwb write + flush aren't bouncing across CPUs
  unnecessarily (zio taskq placement).
NONE of these are PG-specific: they are ZFS/zio/driver/scheduler infra that any sync-fsync workload
on OSv benefits from.

### Phase 3 - SLOG (separate ZIL log device) - the structural lever if flush-bound
If Phase 0 shows the per-commit flush is the dominant cost (vwc==1), a dedicated log vdev (SLOG) on
a fast device absorbs the ZIL and removes the flush from the main pool's write path - the standard
production answer for WAL-on-ZFS. On AWS: a second instance-store NVMe namespace as log. This is a
config/topology change (zpool add log), validated + measured. It is the honest "if you want ZFS WAL
to match ext4, this is how production does it" answer.

## Guardrails (per project mandate)
- Every step MEASURED (commits/sec + NOPM + p99); source-reading is hypothesis, build+measure confirms.
- Generic, not PG-specific: config levers are standard ZFS-for-PG tuning; code levers are ZFS/zio/
  driver/sched infra. full_page_writes=off is justified by ZFS block atomicity, documented, durability
  re-checked - the one PG setting we touch, and it is a correctness-backed ZFS interaction, not a hack.
- Any OSv code fix -> its own reviewable PR, master-eligible, G-signed.
- Let the Phase-0 profile decide the lever; do not pre-commit to Phase 2/3.
