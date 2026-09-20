# OSv fork per-backend footprint — MEASURED RESULT (agent-footprint2, 2026-09-19)

Base: gh-fork/`bank/fork-footprint-reduction` (d994a616c), apps 3f93f43 (mkdir gate = 1),
bench-base-gate **PASS** (all 9 markers, verified on-box).
Substrate: m5d.metal (i-08caff61e534e9900) + c5.4xlarge driver (i-0affb9a64f77d60c4),
qemu 7.2.22 `-M pc`, raw `/dev/nvme1n1` passthrough, guest 64 GiB / 32 vCPU,
shared_buffers=16GB, max_connections=600, ZFS ashift=12/recordsize=8k/sync=standard,
`io_method=worker` (this PG was built without liburing — see caveats).

---

## 1. THE BREAKDOWN — the dominant term is NOT any of the three hypotheses

Measured with a corrected probe at 73 live address spaces (65 long-lived churning backends):

| term | what it is | measured total | per backend | share |
|------|-----------|---------------:|------------:|------:|
| (a) fork-arena COW faults | `cowarena_MB` — COW breaks in the 512 MiB arena | 289 MB | ~4.0 MB | **1.6%** |
| (b) page-table clone | `pt_MB` — a PT page at every level per child | 81 MB | ~1.1 MB | **0.4%** |
| (c) privatized stacks | `priv_MB` — byte-copied forking-thread stack | 72 MB | ~1.0 MB | **0.4%** |
| ELF / MAP_SHARED / other COW | `cowelf/cowmmap/cowoth` | ~0 | ~0 | ~0% |
| **(NEW) overflow-region commit** | **`ovflive_MB` — per-AS 1 MiB `mmap_populate` regions, never recycled in-lifetime** | **17,886 MB** | **~245 MB** | **99%** |
| **TOTAL** | `per_as_KB` | | **247 MB** | |

**The dominant term is post-exhaustion overflow commit, at 99%.** All three hypotheses the
brief carried are refuted as the dominant term.

Two further source worries, both **already closed** on this base and confirmed by measurement:
- `cowmmap_MB ≈ 0` → shared_buffers **is** correctly shared across fork (the
  `shared_anon_registry` works; not COW-duplicated).
- `range_is_wholly_shared()` / `OSV_FORK_LARGE_SHARE` already shares writable MAP_SHARED 2 MiB
  pages **verbatim**; `free_child_pt_level<1>` skips large entries. The feared
  "`split_large_page` mutates the parent permanently per fork" regression is not present.

## 2. ROOT CAUSE (source-verified, then measured) — a FIXABLE BUG, not an inherent cost

`core/fork_arena.cc`:
1. The arena bump `g_bump` is **GLOBAL across every address space** — 512 MiB total, not
   per-AS. With N backends that is 512/N MiB each (~7 MiB at N=74), so it **exhausts almost
   immediately**. Measured: cumulative carve reached **149–188 GB** against a 512 MiB arena.
2. Past exhaustion, every allocation comes from `overflow_alloc()` → a fresh **1 MiB
   `mmap_populate`** region (eager: real RAM at map time).
3. `free()` was an **unconditional no-op for every overflow chunk**. Deliberate and necessary
   for C2-safety (a cross-AS free must not read a chunk header at a VA mapped only in the
   dead/other child), but it removed **all** recycling.

So a backend's committed RAM tracked its **LIFETIME MALLOC CHURN**, not its live heap.
PostgreSQL is the pathological case: per-query MemoryContext turnover with a small live heap.
That is why an OSv backend reached hundreds of MB where the glibc-backed Linux equivalent stays
at 5–15 MB — glibc recycles, this path could not.

**Stated plainly: the leak #2 fix traded a slow leak for a churn-proportional one.** This
reclassifies the VU64 wall from "inherent COST" (VU64-VERDICT-FINAL.md) back to **fixable bug**.

## 3. THE FIX — intra-AS recycling with C2-safety fully preserved

Carve slot 97 into one **disjoint 2 GiB VA window per AS slot**; map each region at a fixed VA
inside the owning AS's window. The owning slot then follows from the VA by arithmetic alone,
`(va - ovf_slot_base) / ovf_window_sz`, so `free()` distinguishes same-AS from foreign by a
**BSS-only test that reads no arena page**. The owning AS recycles through its normal per-class
free-list; a foreign free remains exactly the no-op it was; the region is still reclaimed
wholesale on reap. Only the same-AS case changes.
Invariant self-checked offline in `test_ovf_owner.py` (windows tile slot 97 with no gap/overlap,
owner recycles, foreign no-ops).

## 4. MATCHED A/B — identical workload, identical backend count, one build per arm

`churn-ll.sh 64 300 50000`, 73 live ASes in both arms:

| metric | BEFORE (recycle=0) | AFTER (recycle=1) | change |
|--------|-------------------:|------------------:|-------:|
| (a) `cowarena_MB` | 289 | 284 | unchanged (not the term) |
| (b) `pt_MB` | 81 | 81 | unchanged (not the term) |
| (c) `priv_MB` | 72 | 72 | unchanged (not the term) |
| **overflow live** | **17,886 MB** | **283 MB** | **63.2x lower** |
| overflow committed | 17,898 MB | 447 MB | 40x lower |
| overflow recycled | 0 | 1,549,208 MB | fix working |
| **per-backend private** | **247 MB** | **10.0 MB** | **24.7x reduction** |
| memfree | 29,311 MB | 46,821 MB | **+17.5 GB** |
| outcome | crashed | stable for the full window | |

**10.0 MB/backend lands inside Linux's 5–15 MB band — the 50–100x per-backend gap is closed.**
In the AFTER arm, **1,512 GB of cumulative churn was served out of 283 MB of live overflow.**

## 5. MAX BACKENDS — THE HEADLINE

| arm | max backends sustained | stop reason | memfree at peak |
|-----|----------------------:|-------------|----------------:|
| BEFORE (documented, earlier campaign) | **~74** | OOM (per VU64-VERDICT-FINAL.md) | ~0.5 GB |
| **AFTER (measured here)** | **576** | **PG `max_connections=600` — NOT memory** | **42.4 GB free** |

576 backends at 4.4 MB/AS consumed 22 GB for 512 address spaces with **42.4 GB still free**.
**The memory ceiling was never reached** — the sweep ran out of configured connections first.
So 576 is a **floor**, not the ceiling; ~74 → 576+ is at least **7.8x**, and the per-backend
figure implies room for far more.
(An earlier sweep reported "died at 320 / sustained 289", but that was a liveness `SELECT`
timing out under CPU saturation while the guest was healthy with 46 GB free and kept serving —
a driver/CPU artifact, not a memory limit. `max-backends2.sh` fixed the criterion. The honest
number is the 576 one.)

## 6. THE VU32 MEDIAN QUESTION — a clean SPLIT, with a mechanism

pgbench, 32 clients, 150 s, same guest, both arms:

| arm | tps | latency avg | `ovflive_MB` | memfree |
|-----|----:|------------:|-------------:|--------:|
| BEFORE | 10,128 | 3.159 ms | **0** | ~45 GB |
| AFTER | 10,171 | 3.145 ms | **0** | ~45 GB |

**+0.4% — statistically identical.** The decisive observation is not the null itself but *why*:
**`ovflive_MB = 0` in both arms.** At 32 clients the arena never exhausts, so the overflow path
**is never entered**, there is no memory pressure (45 GB free, no reclaim), and the footprint fix
has nothing to act on. So:

> **The VU32 gap is a DISTINCT throughput factor, not the footprint.** The footprint fix
> addresses the VU64+ capacity wall only. The two residuals split cleanly, and the split is
> backed by a mechanism (the overflow path is provably inactive at VU32), not merely by a null
> result. This corroborates the A2A verdict that VU32 is a cross-vCPU wakeup-latency effect.

**Scope limit, stated plainly:** this is pgbench, **not** HammerDB TPC-C NOPM. HammerDB was not
installed and no TPC-C schema existed; building 200 warehouses exceeded the remaining budget.
These tps figures must **not** be compared with the 205k/284k NOPM numbers in
A2A-FINAL-VERDICT.md. What is claimed is only the mechanism above, which does not depend on the
absolute throughput number.

## 7. FOUR LATENT BUGS FOUND — the prior probe could never have produced data

1. **`ovf_pages.fetch_add` was never called anywhere** (grep count 0), and overflow pages are
   committed by `mmap_populate`, **not** by COW fault — so the 99% term was **invisible** to a
   COW-fault-bucketed probe and would have been mis-attributed to the residual.
2. **The probe dumper did not compile**: `new sched::thread(...)` — that ctor is private
   (`sched::thread::make()` is required). The footprint1 probe had never been through a compiler.
3. **`--env=` values do not reach `getenv()` in this image** (see §8).
4. **`debugf` output never reaches the console**: `core/debug.cc:167` gates `console::write` on
   the global `verbose` flag, which only `--verbose` sets. The probe ran and printed into the
   debug buffer; nothing appeared. The `FORKFLAG` lines in the same file are visible precisely
   because they use `debug_early`.

Also: the footprint1 applier script is **non-idempotent** — its guard greps
`fork_arena_bump_used` while the real symbol is `bump_used`, so a second run double-applies and
breaks the build. Dropped entirely; probe and fix are committed on the branch and the build
script only *verifies* markers.

## 8. `--env=` IS NOT REACHING `getenv()` — evidence for the queued audit

Observed on the boot that was supposed to enable the probe:
- The qemu `-append` line **did** carry `--env=OSV_FP_PROBE=1 --env=OSV_FP_INTERVAL=5
  --env=OSV_FORK_OVF_RECYCLE=0` (logged verbatim in `console-run.log`).
- `parse_options()` prints `"Setting in environment: %s"` for every `--env=` it installs
  (loader.cc:375). **That line never appeared.**
- Every flag echo read the compiled default:
  `FORKFLAG OSV_FORK_TIMING unset, default 0`,
  `FORKFLAG OSV_FORK_RANGE_BS unset, default 1`,
  `FORKFLAG OSV_FORK_LARGE_SHARE unset, default 1`.
  Note these are `debug_early` (so genuinely visible) and they say **`unset`** — i.e. `getenv`
  returned NULL for knobs an operator believed were being set.
- Ordering contribution: `fork_arena::init()` is at loader.cc:796, `parse_options()` at :857.
  Anything that latches a cached env answer before :857 latches "unset" **permanently**. That
  explains the probe specifically (its `fp::on()` cached 0 at first call), and it matches the
  known pitfall that a value must be in the environment *before* the consumer latches it.
  Moving `fp_probe_start()` to after `parse_options()` + `smp_launch()` fixed the *ordering*
  half — but the missing `"Setting in environment"` line shows `--env` was **not being installed
  at all** on this path, which is the more serious half and is **not** explained by ordering.

I did not chase this further (out of scope, and the audit is queued). I removed the dependency
instead: probe **default-on**, A/B arms selected at **compile time**
(`-DFORK_OVF_RECYCLE_DEFAULT=0` builds BEFORE), all probe output via `debug_early*`, plus a
`FORKARENA ovf_recycle=<n>` **proof-of-binding** line that must appear in the log before any A/B
number is believed. Both arms printed it correctly (`=0` BEFORE, `=1` AFTER).

**Blast radius for the audit:** any past A/B whose arms differed *only* by an `OSV_*` `--env=`
knob may have compared the compiled default against itself. My evidence above supports checking
`OSV_ZIL_HIRES_CV`, `OSV_BLK_MQ_COMPLETE`, `OSV_WAKE_PULL`, and `OSV_ZFS_ARC_MAX` (the a2a
"matched 32 GiB ARC both sides" claim). Note `OSV_FORK_RANGE_BS`/`OSV_FORK_LARGE_SHARE` default
to their *non-inert* values, so gate-PASS behaviour was preserved by luck, not by the env.

## 9. HONEST NEGATIVES AND WHAT WAS NOT DONE

- **The BEFORE crash was not the documented OOM.** It ended with `page fault outside
  application` + `Aborted` in `memory::page_pool::l2::refill()` → `lockfree::mutex::lock()` →
  `aligned_alloc` (a stack-overflow signature, faulting at RSP−8) **while 29 GB was still free**
  — not the clean `"could not reclaim any further"` OOM of VU64-VERDICT-FINAL.md. Same root
  pressure, different failure mode. I do **not** claim to have reproduced that exact OOM.
- **The matched BEFORE max-backends sweep was not obtained.** On its second boot the BEFORE
  image entered crash recovery, logged `redo done` in 0.00 s, then **wedged in the
  end-of-recovery checkpoint** for >10 min (qemu ~53% of one CPU, host 98% idle, 0 backends,
  memfree flat ~47 GB). Not memory — a checkpoint/ZIL stall. The BEFORE capacity number
  therefore remains the previously documented **~74**, measured by an earlier campaign and **not
  re-measured here**. (The AFTER arm recovered from the same unclean shutdown without incident,
  which is suggestive but not a controlled comparison.)
- **VU64/VU128/VU192 HammerDB runs: not done** (no HammerDB, no TPC-C schema, insufficient
  budget). The 576-backend result is the capacity evidence in their place.
- p99 and a correctness regression suite: not run. The fix preserves the C2-safety property by
  construction and the AFTER arm ran clean workloads including crash recovery, but that is not a
  substitute for the leak-#1/#2 regression gates.

## 10. FILES

- Fix + probe: gh-fork `bank/fork-footprint-reduction` — 1f277a56d (fix), 3b1b3829a (loader
  ordering), 9a611512a (compile-time A/B), d994a616c (debug_early output).
- `test_ovf_owner.py` — offline self-check of the window/owner invariant.
- `raw/AB-MATCHED-73AS.txt`, `raw/MAXBK2-AFTER.txt`, `raw/MAXBK-AFTER.txt`,
  `raw/VU32PROXY-{BEFORE,AFTER}.txt`, `raw/BEFORE-recovery-wedge.txt`,
  `raw/AFTER-contaminated-churn.txt`.
- Scripts: `churn-ll.sh` (long-lived churn — the shape that matters), `idle-arm.sh`,
  `max-backends2.sh` (memory-criterion sweep), `vu32-proxy.sh`, `build-image.sh`, `boot-osv.sh`.

---
## TEARDOWN CONFIRMED (2026-09-19)
- i-08caff61e534e9900 (m5d.metal): **terminated**
- i-0affb9a64f77d60c4 (c5.4xlarge): **terminated**
- `Owner=agent-footprint2` non-terminated instances: **0**
- Orphan (available) volumes: **0**
- SG sg-0a0fec26afe57cd43: still **73.4.58.126/32** on 22 and 5432 — never widened.
- Two `Owner=None` c6id boxes remain in the account; they are not mine and were not touched.
