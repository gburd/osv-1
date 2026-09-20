# HammerDB scaling re-test with the footprint fix (#3) + the VU32 distinct factor (#4)

## WHY THIS RUN
The footprint fix (per-AS overflow windows + owning-AS recycle) cut per-backend private 247MB -> 10.0MB
(24.7x) and lifted max backends ~74 -> 576 (stopped by max_connections=600 with 42.4GB STILL FREE, so 576
is a floor). Hundreds of backends are now possible for the first time. TWO open questions, same workload,
one box:
 #3 SCALING: with the fix in, does OSv PG-on-ZFS now scale VU64/128/192 vs matched Linux? Previously VU64
    OOM-wedged (that was the footprint bug) and the sweep never got past VU32. This is the real
    "does OSv scale like Linux" test and it also validates the fix end-to-end under real load.
 #4 THE VU32 DISTINCT FACTOR: the footprint study cleanly RULED OUT memory pressure as the VU32 cause
    (+0.4% with the fix, and ovflive_MB=0 in BOTH arms => at 32 clients the overflow path is never even
    entered, so there was nothing to relieve). So the ~0.62-0.72x VU32 median gap vs Linux is a DISTINCT,
    still-unexplained THROUGHPUT factor. Find it.

## BASE (must be the fixed tree, gate-verified)
gh-fork/bank/fork-footprint-reduction-signed @ 1480fbee1 (all 5 commits G-signed, tree byte-identical to
the validated bank/fork-footprint-reduction). Contains: both leak fixes + the 8 cross-AS coherence scopings
+ all 9 perf-fix markers + the footprint fix. apps 3f93f43 (verify grep -c 'mkdir(dst, 0700)'
apps/postgres18-musl/seed_copy.c = 1). RUN .local/bench-base-gate.sh and REFUSE to launch if any marker is
missing. The footprint fix's A/B is COMPILE-TIME on this branch (the agent moved it off env) - confirm from
the boot console which arm you built, and PRINT the resolved value (see the env rule below).

## THE ENV RULE (learned the hard way - see .local/ENV-AUDIT-RESULT.md)
--env= DOES reach getenv() (putenv at loader.cc:374 runs; the "Setting in environment" line is just a
verbose-gated debugf so it is SILENT). BUT a consumer that latches its static BEFORE parse_options
(loader.cc:818) reads nothing - fork_arena::init (759) is in that class. debugf never reaches the console
(core/debug.cc:167 gates on verbose) - use printf or debug_early for proof lines.
=> MANDATORY: for EVERY arm, PRINT the RESOLVED value of every lever to the console and VERIFY it per arm.
   An A/B is INVALID unless you can paste the resolved-value line from each arm's boot log. Never infer
   binding from the command line.

## #3 THE SCALING SWEEP
Matched OSv-vs-Linux, ONE m5d.metal, SAME raw /dev/nvmeXn1 passthrough (cache=none aio=native), SAME ZFS
geometry (ashift=12 recordsize=8k sync=standard), SAME ARC cap both sides, PG 18.6 musl OSv / the same
Ubuntu-glibc-ZFS+io_uring Linux arm the a2a used (libc is the ONE documented caveat), io_method=io_uring
BOTH sides (verify via `show io_method`), fresh-boot-per-cell, hardened quiesce (two consecutive sub-1s
CHECKPOINTs), 3 settled reps per cell, p99 captured, qemu-cpu discriminator per rep.
 - SWEEP VU32, VU64, VU128, VU192 both arms. (VU32 is the #4 anchor; VU64+ is the new territory.)
 - shared_buffers: use a REALISTIC value (the footprint fix should make 16G viable again - if 16G still
   struggles at VU192, note the RAM/sb/backends arithmetic explicitly rather than silently shrinking it).
 - WATCH for regressions of everything fixed: NO EMFILE (leak #1), NO OOM/monotonic mem decline (leak #2 +
   the footprint fix), NO dentry wedge (#1502), and confirm mem stays BOUNDED as VU rises (the footprint
   fix's real test: private memory should now scale ~10MB/backend, not ~250MB).
 - Report the OSv-vs-Linux median + RATIO + p99 at EACH VU, and the per-backend memory at each VU.

## #4 THE VU32 FACTOR (the same box, the same build - investigate while the sweep runs or right after)
Known: NOT memory pressure (ruled out with a mechanism). Candidates to discriminate with the qemu-cpu +
in-guest instrumentation you already have:
 - Is OSv CPU-SATURATED at VU32 (then it is a CPU-efficiency/path-length gap: more cycles per transaction)
   or IDLE/WAITING (then it is a latency/blocking gap)? The qemu-cpu number splits these immediately.
 - If CPU-saturated: where do the cycles go? (syscall path length, ZFS/ZIL write path, scheduler overhead,
   TLB/page-fault churn from 4K vs 2M mappings, lock contention). A profile or a targeted counter.
 - If waiting: what wait_event dominates in pg_stat_activity, and is the matching OSv-side wait cheaper on
   Linux? (WALWrite/ZIL commit latency is the prior suspect - the per-commit recycle-latency deficit the
   whole arc identified. The isolate showed OSv 1.5 vs Linux 13 lwbs in flight.)
 - Compare a NON-durable control (sync=disabled or a read-only workload) OSv-vs-Linux: if the gap VANISHES
   without durable writes, the factor is the ZIL/commit path; if it persists, it is a general CPU/path cost.
   THAT is the cleanest discriminator and it is cheap - run it.
Report which side of the split it is on, and the named factor (or the honest "narrowed to X, not yet pinned").

## SUBSTRATE + hygiene
hotdog: AWS_PROFILE=hotdog, acct 585335547908, region us-east-2 (--region explicit), quota 1152. Keypair
osv-hotdog. SG sg-0a0fec26afe57cd43 (ALREADY /32-scoped to 73.4.58.126 - USE AS-IS, NEVER 0.0.0.0/0, never
widen: a world-open port flags and closes the account). Subnet us-east-2a subnet-04a66ccb68b2a2f13. Debian
12 ami-0dc1629a58a7d6458 (qemu 7.2.22, -M pc; q35 hangs). ONE m5d.metal + a driver. Tag Owner=agent-scale.
hotdog is SHARED (solnix Owner=gregburd + other Owner=None boxes) - only touch YOUR Owner=agent-scale
resources. NEVER SIGKILL qemu mid-CHECKPOINT (it tears the sync=standard ZFS pool). Reuse the scaffolding
in .local/gates, .local/cwwake, .local/footprint2 (boot/build/runcell/instr/quiesce/memprobe all exist).

## OPERATIONAL RULES (a prior agent orphaned an m5d.metal by ending its turn early)
1. NEVER end your turn while a box of yours is live. Work continuously: nohup long steps and POLL them.
2. If you must stop for ANY reason, TERMINATE YOUR BOXES FIRST, confirm 0 orphans, then report.
3. Do local prep BEFORE launching metal where possible.
4. Report your box ids immediately after launch; write results to .local/scale/ AS they exist (off-box).
5. Terminate at the end + confirm 0 agent-scale instances + 0 available volumes.

## DELIVERABLE
.local/scale/RESULT.md with: the OSv-vs-Linux table (median NOPM + ratio + p99 + per-backend MB + qemu-cpu
at VU32/64/128/192), the resolved-lever proof lines per arm, the #4 verdict (CPU-bound vs waiting, and the
named factor or the honest narrowing), and any regression observed. Minimum-viable if budget runs short:
VU64 both arms (proves the fix unwedged it) + the #4 durable-vs-nondurable discriminator. Only MEASURED
numbers - no "scales like Linux" without the pasted table.

## DISPATCHED 2026-09-19: agent ab2f349c (Owner=agent-scale). Combined #3+#4 on one box (shared setup, and
## #4 rides the VU32 end of the same sweep). Base bank/fork-footprint-reduction-signed @ 1480fbee1.
## Awaiting: the OSv-vs-Linux VU32/64/128/192 table (median/ratio/p99/per-backend-MB/qemu-cpu), the
## per-arm resolved-lever proof lines, and the #4 durable-vs-nondurable verdict.

## DRIVER-SATURATION GUARD (steered 2026-09-19): the agent upsized DRV to c5.9xlarge (36 vCPU) unprompted
## so HammerDB is not the bottleneck at VU192 - good instinct. But VU64-192 is NEW territory (the prior a2a
## stopped at VU32 on a 4xlarge), so the confound is closed EMPIRICALLY, not by assumption:
##  - instrument the CLIENT side every cell (driver CPU via mpstat/pidstat on the HammerDB process, load
##    average, and driver<->guest network throughput/packet rate) - the same discipline as the guest-side
##    qemu-cpu discriminator;
##  - any cell with driver CPU >70-80% or network near line-rate is DRIVER-LIMITED/INVALID and must NOT
##    enter the headline table (better to report VU32/64/128 as the valid range than an untrustworthy VU192);
##  - RATIO SANITY: if OSv/Linux converges toward 1.0 while BOTH arms' absolutes flatten, suspect the
##    driver/network first. A wall appearing in BOTH arms at the SAME VU is almost certainly client-side.
## Boxes: METAL i-00b52ea02ffc05430 (m5d.metal, 3.142.98.101), DRV i-0295dadedf57f4f0c (c5.9xlarge).

## ARC FINDING (agent ab2f349c, 2026-09-20) - possibly BIGGER than the ratio it was measuring:
MEASURED (default-on printf ARC probe added to arc_os.c, resolved from the boot console):
  ARCPROBE arc_size_MB=19 arc_c_MB=2047 arc_c_max_MB=32767 zfs_arc_max_MB=0 dirty_max_MB=3276
           free_MB=47759 physmem_MB=65535
=> OSv's ARC TARGET is 2047MB (2GiB) with a 32767MB CEILING and 47GB FREE. zfs_arc_max=0 confirms the
knob is absent/unset. So the 2GB is OSv's STEADY-STATE ARC TARGET, **not** a memory-pressure artifact -
it independently confirms the cwwake MEMPROBE arc_c=2047MB observation and proves it is structural.
ALSO CONFIRMED: OSV_ZFS_ARC_MAX does NOT EXIST on bank/fork-footprint-reduction-signed (it lives only on
gh-fork/bench/zil-hires-ab, b7dff520d/98b5e58c4). So "--env=OSV_ZFS_ARC_MAX" on this base is a SILENT
NO-OP - exactly the env trap .local/ENV-AUDIT-RESULT.md documents, and the agent caught it with a
LEVER-PROOF LINE instead of assuming. This is the audit's discipline working as designed.

## WHY THIS MAY BE THE REAL VU32 EXPLANATION (reframes #4):
19GB dataset vs a 2GB OSv cache while the a2a's Linux had 32GB = a ~16x cache disadvantage. OSv was doing
physical IO where Linux served from RAM. So the a2a's VU32 0.62-0.72x may be LARGELY A CACHE-SIZE ARTIFACT
rather than an OSv execution deficit. The equal-cache (2GiB both) run is the clean test: if OSv/Linux at
VU32 comes out near 1.0 with equal cache, the #4 "mystery throughput factor" is RETIRED as mostly-ARC. If
the gap persists at equal cache, a real execution factor exists and the durable-vs-nondurable discriminator
names it. Either way the experiment is now clean.

## METHODOLOGY DECISION (endorsed): match Linux DOWN to OSv's measured 2GiB (the only achievable TRUE
equality without porting the knob mid-benchmark = changing the thing under test). Stated caveats: (a) a
2GiB ARC on 19GB of data makes BOTH arms far more IO-bound than a real deployment, so this run emphasizes
the ZFS/IO path; (b) the numbers are a NEW baseline, NOT comparable to the prior a2a (Linux at 32G there);
(c) the claim is precisely "at equal cache, OSv vs Linux is X" - NOT a claim about Linux's real-world speed
with an artificially small ARC. Stretch goal if budget: also run each-at-its-own-realistic-cache (OSv 2GB
self-limited vs Linux 32G) = the DEPLOYMENT comparison a user would actually see. Both questions are
legitimate and they are different.

## ELEVATED TO ITS OWN INVESTIGATION: "OSv's ARC will not grow past ~2GB with 47GB free" is a practical
## CRIPPLER for a database host independent of any ratio (it forces physical IO where RAM should serve).
## Steered the agent to NAME the cause if cheap (arc_c_min/max init? missing memory-pressure feedback so
## OSv's ARC cannot see guest free memory? a hard-coded default?) - arc_os.c is the place, and it is already
## instrumented. Do NOT fix mid-run; naming it is the deliverable. This is a strong candidate for the next
## fix after the scaling run - arguably higher practical value than the remaining VU32 delta.

## *** CORRECTION (2026-09-20): MY ARC HYPOTHESIS ABOVE IS REFUTED. The section above is WRONG. ***
The agent refuted it with measurement and is CORRECT. Do not act on the ARC-crippler claim above.
WHY IT WAS WRONG: arc_c=2047MB is OSv's IDLE FLOOR, not a cap.
  arc.c:8042  arc_c_min = MAX(allmem/32, ...) -> 64GiB/32 = 2GiB EXACTLY == the 2047MB observed.
  arc.c:8103  arc_c = arc_c_min at init; arc_adapt (arc.c:5108-5124) GROWS arc_c toward arc_c_max on demand.
  arc_c_max = 32767MB from arc_default_max = MIN(5/8*RAM, RAM/2) = 32GiB. NOT a defect.
  The probe was taken on a QUIESCENT guest with arc_size=19MB - an ARC holding 19MB has no reason to raise
  its target. I read a steady-state-at-IDLE number and generalized it into a structural cap. The 19MB
  arc_size was the tell and I missed it.
MEASURED PROOF (agent drove demand with sequential scans of the 19GB dataset; ARC grew as designed):
  arc_size 19MB (arc_c 2047) -> 2786 (2853) -> 4876 (4935) -> 6572 (6647) -> 7460 (7563) MB,
  free falling 47742 -> 40197 MB, still climbing toward the 32767MB ceiling.
=> OSv's ARC DOES use the guest's RAM. There is NO "OSv cannot cache" finding. The a2a's VU32 gap is NOT
   explained by a 16x cache disadvantage - under HammerDB load OSv's ARC would have grown the same way.
=> THE #4 VU32 QUESTION IS **NOT** RETIRED. It remains a real, open throughput factor; the durable-vs-
   nondurable discriminator is still the way to name it.
DECISION REVERSED (endorsed): KEEP Linux at zfs_arc_max=32GiB. My "match Linux DOWN to 2GiB" instruction
would have PINNED LINUX AT ITS FLOOR while OSv grew to ~32G under load = HANDICAPPING LINUX AND INFLATING
OSv - the exact error class the campaign already had to retract once (the original "OSv 2.9x faster" came
from a handicapped Linux baseline). TRUE parity = equal CEILING: Linux zfs_arc_max=32GiB vs OSv measured
arc_c_max=32767MB already match within rounding, which is what the a2a actually had. So the run stays
comparable to the a2a. Both arms report measured arc_c/arc_size per cell so cache state is auditable.
LESSON (standing): never infer a CAP from an IDLE sample. Measure the resource under the LOAD that would
drive it, and check the companion value (here arc_size=19MB) that reveals whether demand even existed.
