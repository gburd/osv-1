# PROJECTED-MAX NATIVE RUN - RESULT

**Box ids (all Owner=agent-projmax, all terminated at the end of this run; see section 9):**
`i-09805e3de484e1039` builder, `i-00eb5d4605d588a4d` driver,
`i-082c10d52326a3cb9` OSv arm (first image, replaced), `i-0f56b22744720a667` OSv arm (final image),
`i-0f160cde3349d0863` Linux arm. Artifacts: `ami-00f1b59e07c5792ab`, `ami-02d7a5e0ff3ba4c13`,
`snap-018992a6f3381a2f6`, `snap-` for the second AMI (both deregistered/deleted below).
No box, AMI or snapshot belonging to `agent-rootcause` or to `Owner=None` was touched.

---

## 0. WHAT THIS RUN ACTUALLY DELIVERED, AND WHAT IT DID NOT

Delivered: a **booting near-maximal image** with **#1513 vdev_nonrot proven LIVE AT RUNTIME**,
**one matched RO cell** and **one matched RW cell** at VU32 with all reps, medians, spreads and
client-side instrumentation. That is the stated minimum viable result.

NOT delivered: VU64/128/192. I spent the run's budget on composition correctness instead, because
the composition work uncovered three defects that invalidate how previous numbers were framed -
including one that silently removed a fix from **every image this campaign has ever built**. I judged
that finding worth more than four more cells, and I am flagging the trade rather than hiding it.

**The single most consequential sentence in this document:** the base is 24 commits behind
upstream/master, so this run - and the last native run - measured *the fork stack as of fork point
`cb8c7205b`*, **not** the projected-merged future. See section 2.

---

## 1. THE COMPOSED IMAGE

Branch **`gh-fork/bench/projected-max`** @ **`bcec6c61cd4d61bb62a554af31b2c89d5a5e532f`**
(pushed to gh-fork; `%G?` = G on all 6 commits). Base `75f421ae3` (177 commits).
apps pinned `3f93f43`. OSv `v0.57.0-557-gbcec6c61`.

| # | commit | what |
|---|---|---|
| 1 | `59135661b` | zfs: report solid-state vdevs as non-rotating (#1513 equivalent, patch form) |
| 2 | `1748578e8` | zfs: fix the 0044 hunk count + prove vdev_nonrot at runtime (0045) |
| 3 | `113554783` | build: order bootfs prereqs for any ZFS build and for fs=ramfs (#1494+#1496) |
| 4 | `d8016a034` | drivers, vfs: validate completion ids (#1450) + physio iovec (#1508) |
| 5 | `5b3cf9438` | build: fail the build when the OpenZFS patch series does not apply |
| 6 | `bcec6c61c` | zfs: repair patch 0032 so the synchronous ARC shrinker actually applies |

**Proof it built:** `LOADER_MB=183` (PG baked into the ramfs image; ~8 MB would mean a PG-free
failure), `BARE_MB=56`, `POSTGRES_IN_MANIFEST=6`, `LIBSOLARIS_IN_MANIFEST=1`,
`OZFS_PATCH_SERIES_OK (0 skipped)`, 45 patch files applied. No CI exists on any of this, so
"builds" means I built it, twice, from a clean clone.

### 1a. #1513: the brief's instruction was unexecutable, and the reason matters

The brief said to cherry-pick `pr/zfs-vdev-nonrot @ 18194d253` and prefer the PR version. **That
cannot work on this base.** #1513's head sits on `0e34e4dc2` and edits
`modules/open_zfs/osv/module/os/osv/zfs/vdev_disk.c` - a path that **does not exist** in this base,
which carries the OSv ZFS platform layer as 43 sequential `.patch` files against a vendored
checkout instead. The brief's grep returned nothing for the right reason but the wrong diagnosis:
not "the fix is absent" but "the fix cannot be expressed against this tree".

Used instead: `bank/iouring-completion-fix @ 51f69a04c`'s `patches/0044-zfs-vdev-nonrot.patch`,
which is the identical semantic change (`vd->vdev_nonrot = B_TRUE` in `vdev_disk_open`) in the form
this base can apply. Confirmed the 43 shared patch files and the openzfs submodule pin are
byte-identical between `51f69a04c` and the base, so 0044 is a pure add.

### 1b. Patch 0044 shipped CORRUPT and was being silently rescued

`0044`'s hunk header claims `@@ -103,6 +103,32 @@` for a body of **37** lines. Plain `git apply`
rejects it (`corrupt patch at line 85`); only the Makefile's `--recount` retry made it apply. It
worked, so nobody noticed - but a patch that needs `--recount` is one context drift from being
skipped outright, and the skip was silent (section 3). Corrected to the true count; it now applies
with no retry.

### 1c. Per-PR verdict table, all 58

Method: per-hunk reverse-apply in a worktree checked out AT the base, **cross-tabbed with a forward
apply**. The cross-tab is what the brief's method lacked, and it is the difference between "absent"
and "cannot tell":

| REV | FWD | verdict |
|---|---|---|
| all | fail | PRESENT (base carries it) |
| none | clean | ABSENT-CLEAN (genuinely missing, applies) |
| none | fail | **DIVERGED / STRUCTURE-MISMATCH** - a reverse-only test calls this ABSENT. **That is a false ABSENT, and it is 24 of the brief's 39 "PARTIAL" entries.** |
| some | fail | PARTIAL |

**PRESENT (9)** - every hunk reverse-applies; brief agreed; no action:
`#1465 #1471 #1479 #1480 #1481 #1485 #1486 #1504 #1507`

**ADDED (5):**

| PR | verdict | evidence |
|---|---|---|
| #1513 | ADDED (via 0044 patch form) | see 1a; runtime-proven live, section 4 |
| #1494 | ADDED | applied clean; merged with #1496, same `ifeq` region |
| #1496 | ADDED | same commit; **replaces the native build script's hand-rolled "build mount tools first" workaround** |
| #1450 | ADDED | applied clean, no resolution needed |
| #1508 | ADDED | applied clean; **no in-tree caller**, so inert here - included for completeness, cannot move a number |

**SKIPPED-INERT (6)** - each declared to preflight via `BENCH_SKIP_PRS` with a reason, so
"excluded on purpose" is machine-distinguishable from "forgotten":

| PR | why inert FOR THIS WORKLOAD |
|---|---|
| #1490 | aarch64 temporary phys map; this is x86_64 |
| #1491 | aarch64 GICv3 SGI cap; this is x86_64 |
| #1498 | AHCI ATAPI boot hang; native boots from NVMe, no AHCI device present |
| #1500 | lwext4 commit pin; ext4 entirely unused by PG-on-ZFS |
| #1440 | inotify(2); PG does not use inotify, and the PR conflicts against master |
| #1497 | **SUPERSEDED-BY-BASE**: the base already generates the `libsolaris.so` manifest entry from `modules/open_zfs/module.py` at import time, which is strictly better than the PR's static file because the provider carries it through module resolution. Verified `LIBSOLARIS_IN_MANIFEST=1` in the built image. |

**The 41 the preflight called UNDETERMINED, resolved to a mechanical cause.** UNDETERMINED is not a
verdict, it is "the cheap test cannot tell". Every one resolved:

| cause | count | PRs |
|---|---|---|
| **STRUCTURE-MISMATCH** (a file the diff touches does not exist in this base) | 18 | #1513 #1510 #1506 #1505 #1488 #1487 #1482 #1478 #1459 #1458 #1449 #1445 #1444 #1442 #1441 #1439 #1438 #1424 |
| **BASE-DIVERGED-PARTIAL** (base carries a different, usually newer, version of the same region) | 12 | #1512 #1511 #1509 #1503 #1502 #1483 #1475 #1472 #1470 #1463 #1456 #1455 |
| **BASE-DIVERGED-NONE** (same region, wholly different content) | 9 | #1499 #1495 #1493 #1492 #1484 #1477 #1467 #1464 #1461 |
| **MERGED-BY-HAND** (I applied it with a manual resolution, so neither direction matches verbatim) | 2 | #1494 #1496 |

Four of the STRUCTURE-MISMATCH cases are worth naming, because the cause is not the ZFS
restructure: **#1438 #1441 #1445 #1482 all touch `core/numa.cc`, which does not exist in this base
because it was added by `a92c44f9b` - one of the 24 missing upstream commits.** So the entire NUMA
PR stack is unapplicable to this base by construction, not by conflict. That is a rebase
dependency, not a merge decision.

**CONFLICT-DEFERRED (8 PRs conflict against master).** Resolved: **#1494+#1496** (mechanical - both
add an `else` to the same `ifeq`; merged by nesting so a `conf_zfs=openzfs fs=ramfs` build gets both
sets of prerequisites, which an else-if chain would silently deny). Deferred:

| PR | why deferred | what it would have contributed |
|---|---|---|
| #1438 #1441 #1445 | depend on `core/numa.cc` from a missing upstream commit; applying them needs the rebase, not a conflict resolution | NUMA topology reporting, node-preferring allocation, per-node L2 pools. Potentially relevant on a 2-socket box, but m5d.8xlarge is single-socket, so inert here even if applied. |
| #1449 | touches `tests/tst-ext-readlink.cc`, absent from this base | ext4 heap-overflow hardening; ext4 unused here |
| #1456 #1475 | 36/55 hunks already reverse-apply, i.e. the base carries most of the fork-COW work in an evolved form. Resolving the remaining 19 needs a design decision about which version wins. **I will not invent a semantic resolution to get a build.** | fork COW refinements; the base's fork stack already serves 400+ backends |
| #1458 | tracking draft, 169 files, superset of the fork work; brief says do not apply as a unit | nothing new; it is the umbrella |
| #1466 | third-party, see section 7 | - |

---

## 2. THE BASE'S TRUE POSITION - THE FRAMING CORRECTION

`git merge-base --is-ancestor upstream/master 75f421ae3` = **NO**. Fork point **`cb8c7205b`**,
**24 commits behind**. The base predates `0e34e4dc2`, which restructured `modules/open_zfs` from a
43-patch series into checked-in sources, which is why 37 of 58 PR heads sit on a tree shape this
base does not have.

**Consequence, stated plainly: neither this run nor the last native run measured "everything we
intend to upstream". Both measured the fork stack at `cb8c7205b`.** The numbers are not wrong; the
framing was. `bench-base-gate.sh` passed every time because it checked 9 *content* markers and
never asked whether the base was *current*.

The 24 missing commits, with relevance to what is being measured:

| commit | relevance to a native NVMe/ZFS PG workload |
|---|---|
| `ae077860c` virtio-blk: do not hold the per-queue lock while draining completions | **HIGH interest.** A lock-contention fix on a completion path, and our wall's signature is "not CPU-bound but cannot go faster". Inert on *these* arms (NVMe, not virtio-blk) but directly on-theme. |
| `0e34e4dc2` zfs: selectable in-kernel ZFS via upstream OpenZFS | **structural.** The reason 18 PRs are STRUCTURE-MISMATCH. Any future benchmark must be on this. |
| `a92c44f9b` numa: discover topology from ACPI SRAT/SLIT | adds `core/numa.cc`; blocks 4 NUMA PRs. Single-socket here, so inert for the numbers. |
| `343b8ca74` libaio: Linux async I/O interface | PG18 uses `io_method=sync` here, so inert for this config, but changes what `io_method` options are testable. |
| `a5ed68053` virtio-net: keep RX mbuf refcount inside the receive buffer | correctness on the RX path; these arms use ENA, not virtio-net. Inert here. |
| `af27ba4b7` libext: real fsync + page-cache bridge | ext4 unused. Inert. |
| `a4d3abd8e` mm: mremap(2) | PG does not mremap on this path. Inert, but a real gap for other apps. |
| `0be0299e4` mm: membarrier(2) | PG18 does not require it. Inert here. |
| `1b809fc80` fs: close_range(2) | PG uses it opportunistically at backend start; possible minor fork-path effect, unmeasured. |
| `95f478cb7` vfs: reject oversized iovcnt instead of panicking | robustness; PG does not emit oversized iovcnt. Inert. |
| `738229eac` libc: splice/vmsplice/tee | unused by PG. Inert. |
| `70446eb44` loader: recognize ld-musl soname | **relevant to how this image is built** (musl PG), though the base's own path already works. |
| `07f61154a` fs: validate ROFS metadata + symlink off-by-one | image uses ramfs, not ROFS-on-disk. Inert. |
| `9450d690d` libc: setrlimit/getrlimit consistent | PG calls setrlimit for core size; inert at these settings. |
| `327305895` fs: preadv2/pwritev2, renameat2 | PG18 can use pwritev2; unmeasured, plausibly relevant to the write path. |
| `6c9d0489b` libc: POSIX default-ignore for SIGCHLD/SIGURG/SIGWINCH | PG forks heavily and handles SIGCHLD itself. Inert but adjacent to the fork path. |
| `bf16817c9` libext inode deletion time, `b7a652efa` ext-disk-utils, `d7c3cb81a` tests Makefile union-merge, `626d53105` comment reword, `af96db0f7` copyright, `dc6ddfe72` apps update, `fa9d104bc`/`75e4b93ae` setrlimit merges | no bearing on this workload |

**Follow-on task, NOT attempted here (per instruction): rebase the 177-commit fork stack onto
current upstream/master.** Size assessment: the 43-patch ZFS series must be re-expressed against
checked-in sources (`0e34e4dc2`), which is the bulk of the work and is not mechanical - at least
0032, 0035, 0036, 0040 and 0044 have line-number or context rot that a rebase will surface all at
once. The NUMA PRs then become applicable. I would budget this as its own run, not a step inside
one.

---

## 3. THE SILENT-SKIP DEFECT: A FIX WAS MISSING FROM EVERY IMAGE THIS CAMPAIGN BUILT

The Makefile's OpenZFS apply chain **could not fail**, while its own comment claimed it would
("FAIL LOUDLY on a patch that cannot apply"). Four independent defects, all in one 10-line block:

1. the skip notice went to **stderr only**;
2. `$skipped` was echoed and **never acted on**;
3. **`ok` was initialised to 1 and never assigned anywhere else**, so `[ $ok = 1 ] && touch stamp`
   always touched the stamp and the `OZFS-PATCH-SERIES-INCOMPLETE` branch was **unreachable dead
   code**;
4. the stamp was touched **unconditionally, before** that check - and the stamp is what makes the
   step idempotent, so a skipped patch was **never retried**.

And the harness completed the failure: `build-osv.sh:116`, the line that *triggers* the apply, read
`make -n ... >/dev/null 2>&1 || true`, discarding the one diagnostic that existed and swallowing the
exit code. A build missing a ZFS fix reported SUCCESS and then hid it from every rebuild.

**What was actually lost: patch 0032, "make the ARC shrinker synchronous in hard mode so the
reclaimer does not OOM".** Its own commit message names the symptom it fixes: *"the VU192
out-of-memory abort seen at high concurrency"*. Root cause of the rot: 0032's second hunk targets
`zfs_initialize_osv.c` at `@@ -1,4 +1,5 @@`, expecting the file to open with the `noshrink` extern;
the file was later rewritten with a ~60-line SPDX/architecture header, putting that extern at line
50 of 363. Context gone, so it fails with **and without** `--recount`. Verified absent from the
built tree: `grep shrink_sync` returned nothing and `osv_arc_lowmem()` still called the async
`arc_reduce_target_size_noshrink()`.

**So the last native run's high-VU cells - including VU192 RO at 0.27x - were measured on an image
whose VU192-OOM fix was silently absent.** This qualifies the high-VU cells. It does **not**
invalidate the whole curve: the VU32 and VU64 cells are unaffected by a reclaim path that only
engages under memory pressure, and no OOM was observed in those cells.

**Repaired for this run** (`bcec6c61c`): the arc.c half applied fine; only the 2-line consumer hunk
had rotted, so I re-anchored it against the current file - one extern, one call swapped to
`arc_reduce_target_size_shrink_sync()`. No semantic change. Verified live in the built tree
(`shrink_sync` present in both `zfs_initialize_osv.c` and `arc.c`). **My RO/RW VU32 cells below
therefore carry the OOM fix, and the last run's did not - a second changed variable, declared.**

**Mechanism fixed generically** (`5b3cf9438`, openable as a standalone PR): failed patch recorded to
`.osv-patches-failed`, build **aborts**, stamp written only on a clean series, failure **sticky** so
the report names the one broken patch rather than every patch skipped by a half-patched retry, and a
`--recount` rescue is now **reported**. Also fixed `build-osv.sh:116` to stop discarding stderr.

**Two bugs in my own first version, both found by negative-testing it** - and worth recording,
because a gate nobody negative-tested is exactly what created this situation:
- `$(shell ...)` **captures stdout**, so an `echo` inside it is swallowed, not printed. That is half
  of why the original notice was invisible even before the harness discarded stderr.
- `$(error)` text is **re-scanned by make**, so a message containing `file.patch: ...` is parsed as
  a rule and dies with `multiple target patterns`, hiding the very reason it was reporting.

**The series audit the operator asked for.** Now that a rescue is reported, three more patches are
in the same one-edit-from-silent-skip state: **0035, 0036, 0040** (wrong hunk counts, applied only
via `--recount`), plus **0044** before I corrected it. 0032 was the only outright failure.

**Not attempted here, required follow-on:** upstream/master **also lacks the 0032 ARC fix** - its
checked-in `zfs_initialize_osv.c` calls the async variant and `arc_reduce_target_size_shrink_sync`
does not exist there. So the spurious-OOM path is **live in master** and wants its own PR against
the restructured sources. Noted, not opened, per instruction.

---

## 4. #1513 PROVEN LIVE AT RUNTIME (not merely present in source)

Source presence is explicitly not sufficient evidence. Two proof lines were added (`0045`), both
`printf` - never `debugf`, which is verbose-gated and silent by default.

**Boot console, OSv arm `i-0f56b22744720a667`:**
```
OSv v0.57.0-557-gbcec6c61
NONROTPROOF nonrot=1 default=1 agg_cap_nonrot_KB=128 agg_cap_rot_KB=1024 vdev=/dev/vblk1
IDLE_SPIN_PROOF adaptive=1 cap=100000 floor=256 shrink_after=4
WAKE_PULL ON
RNGPROOF rdrand=1 rdseed=1 hwsrc_empty=0 seeded=0
ashift 12 / recordsize 8K / sync standard  (read back from the live pool)
```

**The binding proof - device requests, sampled under live write load during the RW VU32 cell:**
```
VDEVIO bios=1219 bytes_MB=60 gt128k=0 maxlen_KB=128
VDEVIO bios=1269 bytes_MB=61 gt128k=0 maxlen_KB=128
VDEVIO bios=1327 bytes_MB=62 gt128k=0 maxlen_KB=128
VDEVIO bios=1376 bytes_MB=62 gt128k=0 maxlen_KB=128
VDEVIO bios=1425 bytes_MB=63 gt128k=0 maxlen_KB=128
```
`gt128k=0` with `maxlen_KB` sitting **exactly at 128** is the signature of the non-rotating cap
binding: requests reach the cap and never exceed it. Under the old rotating default the cap is
1 MiB. **#1513 is live, not merely compiled in.** Absolute bytes are reported, not per-transaction
ratios, per the rule that produced a bogus 4.8x once.

---

## 5. THE CURVE - VU32, both arms, all reps

Substrate: native on-instance, **non-metal Nitro m5d.8xlarge**. OSv owns MBR + ENA + both local
NVMe + all 32 vCPUs; no QEMU, no Firecracker, no KVM. Nitro remains beneath the instance type but
**equally beneath the Linux arm**, which runs on the same instance type as its own host OS. **This
is not bare metal and must never be called that.** libc differs (musl vs glibc): the one accepted,
documented caveat. Driver: `i-00eb5d4605d588a4d`, 36 vCPU, separate box, pgbench 18.6 both arms.
PG 18.6 both arms, GUCs byte-identical to the last native run and read back from the running server.
ZFS geometry `ashift=12 recordsize=8k sync=standard compression=off atime=off logbias=latency
primarycache=all`, verified per cell from the live pool on both arms. Dataset re-seeded per cell
(`pgbench -i -s 100`).

### RO (pgbench -S, 60 s/rep, 3 reps)

| arm | rep1 | rep2 | rep3 | MEDIAN | SPREAD | lat ms | lat sd | drv cores | failed |
|---|---|---|---|---|---|---|---|---|---|
| OSv | 155,975 | 170,375 | 171,491 | **170,375** | **1.10x** | 0.188 | 0.093 | 2.67/36 | 0 |
| Linux | 194,041 | 190,954 | 192,932 | **192,932** | 1.02x | 0.166 | 0.040 | 3.45/36 | 0 |

**RATIO 0.883x**

### RW (pgbench TPC-B-like, 60 s/rep, 3 reps)

| arm | rep1 | rep2 | rep3 | MEDIAN | SPREAD | lat ms | lat sd | drv cores | failed |
|---|---|---|---|---|---|---|---|---|---|
| OSv | 1,583 | 1,923 | 2,340 | **1,923** | **1.48x** | 16.635 | 12.225 | 0.29/36 | 0 |
| Linux | 19,841 | 20,648 | 20,541 | **20,541** | 1.04x | 1.550 | 0.890 | 2.16/36 | 0 |

**RATIO 0.094x** - and see section 6a, because **I do not trust this cell** and I am saying so
rather than publishing it as a finding.

**No cell was driver-limited.** Driver peak 3.45 of 36 cores (9.6%) in the busiest cell, network
peak 25 MB/s tx on a 10 Gbit NIC. Zero failed transactions in all 12 reps.

**arc_c and arc_size MEASURED per arm, never asserted** (`arc_c` starts at `allmem/32` and grows):
OSv `arc_c=4,006 MB`, `arc_size=112 -> 118 MB`, `arc_c_max=64,105 MB`, `free=110,088 MB` of
128,211. Neither arm came near its ceiling, so the differing `arc_c_max` defaults did not bind.

---

## 6. THE A/B VERSUS THE LAST NATIVE CURVE

Same substrate, same methodology, same instance type, same driver, same GUCs, same ZFS geometry.
**Variables changed: the base (as intended) AND the 0032 OOM fix (discovered mid-run).** Two
variables, not one - declared rather than glossed.

| cell | last native run | this run | delta |
|---|---|---|---|
| RO VU32 | 0.96x (156,327 / 163,234) | **0.883x** (170,375 / 192,932) | -8% ratio |
| RW VU32 | 0.16x (3,007 / 18,760) | **0.094x** (1,923 / 20,541) | -41% ratio |

### Did the fuller stack move RO?
**No, not detectably in the right direction.** OSv's absolute RO throughput went *up* (156,327 ->
170,375, +9%), but Linux's went up more (163,234 -> 192,932, +18%), so the ratio fell. Both arms
moving together by ~10-18% on identical instance types points at instance-to-instance variation
(different physical hosts, different noisy neighbours) rather than at anything in the image. **With
one VU level and no repeat of the Linux arm on a second instance, I cannot separate a real -8%
regression from host variance. I am not claiming either.**

### Did #1513 move RW?
**It did not improve it, and the cell it should have improved is the one I do not trust.**
`vdev_nonrot` is proven live (section 4), and the theory is sound: the last run's RW arm treated
NVMe as rotating, aggregating to 1 MiB with 4 KiB gap-stitch. But RW went *down* (0.16x -> 0.094x).
Note this is consistent with the original `51f69a04c` A/B, which measured **NOPM -3.0%** and
explicitly framed vdev_nonrot as a **correctness and latency fix, not a throughput win** - the
withdrawn-table document says so in as many words. So "no throughput gain from #1513" reproduces
prior art. The *additional* 40% loss is not explained by that, and section 6a is the reason I will
not attribute it to the image.

### 6a. WHY I DO NOT TRUST THE RW CELL - and the anomaly it exposed

The OSv RW reps **rise monotonically**: 1,583 -> 1,923 -> 2,340 (1.48x spread, one-sided; Linux
reproduced at 1.04x). A monotonic climb across reps is the signature of a cell that **has not
settled**, not of a stable service rate. A 4th rep on the same boot read **2,680** - still climbing,
now 1.69x above rep 1. So the median 1,923 is an artefact of where I stopped sampling, and the
ratio computed from it is not a measurement of anything stable.

**Then the arm stopped serving.** A follow-up 3-rep cell returned `rc=1` on all three reps: port
5432 dead. Checked before concluding anything, per the standing rule:

- **no OOM, no panic, no assert, no page fault** anywhere in the console (`grep -icE` = 0);
- **110,088 MB of 128,211 free** (86%) - so **not** the reclaim stall that is symptom-identical to a
  lost wakeup;
- **the kernel is still alive**: ARCPROBE lines continue to appear on the console after the port
  died;
- **the Linux arm stayed up** throughout (`LIN_UP`), so this is one-sided and on our side.

This is **anomaly (b) from the last native run reproducing**: *"network dies while the kernel
lives"*. Last run it hit the adaptive=0 VU64 cell, cleared on stop/start, and was not attributable
to the idle-spin lever. Here it hit RW VU32 on a different image. **Two occurrences, two images,
two different cells, same signature: the kernel keeps running and printing while the listener
stops accepting.** That makes it a real, reproducible OSv defect rather than a one-off, and given
it kills cells mid-sweep it is plausibly the reason RW cells are hard to settle at all. **I could
not localize it** and I did not chase it, but it is now corroborated and it deserves its own
investigation - I would rank it above another VU sweep.

---

## 7. THIRD-PARTY PRs (read only; NOT adopted, NOT tested, nothing opened)

| PR | author | relevant or inert here | finding |
|---|---|---|---|
| **#1390** | wkozaczuk | **RELEVANT and we lack it entirely** | `mutex: spin a little in lock() to avoid context switch`. **`git grep -c spin -- core/lfmutex.cc` is 0 on our base AND on upstream/master.** So contended-mutex context switching is **wholly un-mitigated in every number this campaign has produced**, and this is the closest existing candidate for the "59.2% CPU with 13.1 vCPU idle, cannot go faster" signature. It ships with `spin_max=20`, tracepoints, and 6 `CONF_` switches still in tuning state. **Not added** (not ours, and it is mid-tuning). |
| **#1466** | wkozaczuk | inert for these arms (NVMe, not virtio-blk) | **DESIGN CONFLICT with our #1509, confirmed from the diffs.** Both rewrite the same virtio-blk completion path to one thread per virtqueue. **His replaces** the single-completion-thread design (-162/+108; his body says it "reverts some of the changes made to have a single completion thread handle all queues"). **Ours makes it a switch** (`OSV_BLK_MQ_COMPLETE`, default on, single-thread retained as fallback; +133/-31). Same goal, incompatible shapes - these cannot both land. His PR also sets `run.py` num-queues=1, which changes the default our #1509 numbers were taken under. He is the older design intent and the merger, so this is resolved by conversation, not by a unilateral rebase; **#1509 should not be pushed further without addressing the overlap.** |
| #1215 | gohar94 | inert | `ht_enabled -> smt` rename, cosmetic |
| #1288 | wkozaczuk | inert here | signals: switch to app TLS if available; not on PG's path in this config |
| #1338 | nmeum | inert | SCHED_RR; PG does not request RR scheduling |

---

## 8. PREFLIGHT OUTPUT (the new gate, on this tree)

```
bench-preflight: /home/gburd/ws/osv/.local/projmax/wt-compose @ bcec6c61c
  note [ancestry] base is 24 commits behind upstream/master (allowed by BENCH_ALLOW_STALE_BASE)
  note [ancestry] results MUST be described as the fork stack at cb8c7205b, NOT as projected-merged
  ok   [prs] derived 58 open PRs from GitHub
  note [pr#1500] skipped: lwext4-pin-ext4-unused-by-this-workload
  note [pr#1498] skipped: ahci-atapi-native-boots-from-nvme-not-ahci
  note [pr#1497] skipped: superseded-base-generates-the-manifest-entry-in-open_zfs-module.py
  note [pr#1491] skipped: aarch64-gicv3-only-inert-on-x86_64
  note [pr#1490] skipped: aarch64-phys-map-only-inert-on-x86_64
  note [pr#1440] skipped: inotify-conflicting-and-pg-does-not-use-inotify
FAIL [prs] UNDETERMINED for these PRs (diff applies in neither direction ...): 1513 1512 1511
       1510 1509 1506 1505 1503 1502 1499 1496 1495 1494 1493 1492 1488 1487 1484 1483 1482 1478
       1477 1475 1472 1470 1467 1464 1463 1461 1459 1458 1456 1455 1449 1445 1444 1442 1441 1439
       1438 1424
  ok   [prs] no open PR is fully absent from the base
  ok   [ozfs] 45 patch files present
  ok   [buildlog] no skipped or failed patches in the build log
  note [buildlog] 2 --recount rescue(s): a rescued patch is one edit from a silent skip
  ok   [runtime] 3 resolved-lever line(s) in the guest console
bench-preflight: REFUSING TO BENCHMARK -- see FAIL lines above.
```

**Verdict as first real user: the gate is sound and its FAIL is legitimate.** All 41 UNDETERMINED
entries are real "cannot tell from a diff alone" cases and I resolved every one by hand (section
1c). It agreed with my independent per-hunk measurement on all 9 PRESENT PRs - zero contradictions.
Checks 3, 4 and 5 each did their job: the build log scan confirmed 0 skips, the recount note caught
the 0044-class problem, and the runtime check confirmed live levers.

**One real bug, worth fixing before the next user hits it:** the script `cd "$TREE"` at line 59, so
**relative `--build-log` / `--runtime-proof` paths are resolved against the tree, not the caller's
cwd**, and report `file not found` for files that exist. That is a **false negative on the two
checks that exist to catch silent-skip and unproven-lever** - the highest-consequence place to have
one. Absolute paths work. Fix: resolve both to absolute before the `cd`.

**Two non-bugs I checked and cleared:** (a) `#1494`/`#1496` appearing as UNDETERMINED is *correct* -
I merged them by hand so neither direction applies verbatim; (b) `#1450`/`#1508` reverse-apply
cleanly because I applied them verbatim, which is the gate working as designed.

---

## 9. CLEANUP

See the terminal transcript at the end of this run: all 5 instances terminated, both AMIs
deregistered, both snapshots deleted, and a final `describe-instances` filtered on
`Owner=agent-projmax` returning empty. `agent-rootcause`'s two boxes and all `Owner=None` boxes were
never touched.

---

## 10. WHAT I AM NOT CLAIMING

- **This is not the projected-merged future.** It is the fork stack at `cb8c7205b` plus 5 additions.
  24 merged-upstream commits are absent, including the ZFS restructure and a virtio-blk lock-contention
  fix. The rebase is a separate task.
- **Not a clean single-variable A/B.** Two variables moved versus the last native curve: the base,
  and the 0032 OOM fix that I discovered was missing from both runs' predecessors and repaired in
  mine.
- **No VU64/128/192.** Only VU32 was measured, both modes. **No extrapolation** to higher
  concurrency, other instance types, other scale factors, or metal. A prior table was withdrawn for
  exactly that.
- **The RW ratio 0.094x is not a result.** The cell did not settle (monotonic 1,583 -> 2,340 ->
  2,680) and the arm then stopped serving. I report the reps because the rules forbid voiding them
  without evidence, but I am explicitly **not** offering 0.094x as a measurement of anything.
- **The RO -8% ratio change is not attributed.** Both arms moved up ~10-18% on identical instance
  types; I cannot separate image effects from host variance with one VU level and no second Linux
  instance.
- **#1513 moved no throughput here, which is consistent with prior art, not a refutation of it.**
  Its own A/B measured NOPM -3.0% and framed it as a correctness/latency fix. What this run adds is
  that it is **provably live** (`gt128k=0`, `maxlen=128 KiB`).
- **No mechanism for the OSv/Linux gap.** I did not re-measure CPU headroom, so I neither confirm nor
  extend the last run's "not CPU-bound at its ceiling" observation.
- **The "network dies while the kernel lives" anomaly is corroborated, not diagnosed.** Two
  occurrences across two images and two different cells; no OOM, no panic, 86% memory free, kernel
  still printing. I did not localize it.
- **The 3.61x one-sided VU32 RO spread did NOT recur** (1.10x this run, see section 11). One cell,
  one image - that is evidence of non-recurrence in this configuration, **not** evidence the
  underlying defect is fixed. Nothing in this composition targeted it.
- **`#1390` is a lead, not a finding.** I read the diff and confirmed we lack mutex spinning
  entirely. I did not test it, and "plausible mechanism" is not "measured cause".

---

## 11. DID THE 3.61x ONE-SIDED VU32 SPREAD RECUR?

**No.** OSv RO VU32 spread this run: **1.10x** (155,975 / 170,375 / 171,491). Last run: **3.61x**
(46,478 / 156,327 / 167,641) with a slow rep that *settled downward*. Rep 1 here is 9% below the
other two, which is a mild cold-start shape and nothing like a bistable service rate.

Linux reproduced tightly both runs (1.02x here, 1.07x last), so the one-sidedness that made the last
result suspicious is absent this time.

**Caveat stated in full:** this is a single cell on a single image on a single instance. The last run
also showed the spread was *intermittent* (4 extra reps on one boot spanned 1.59x), so a
non-recurrence in 3 reps is weak evidence. **I am not claiming the defect is gone, and nothing in
this composition was aimed at it.** The RW arm did produce a one-sided 1.48x spread with a
monotonic climb plus a hung listener (section 6a), so an unstable-service-rate family of symptoms
is still present on our side - it moved from RO to RW rather than disappearing.
