# Fork per-backend footprint: ROOT-CAUSED + FIXED (2026-09-19, agent c1991ff6) - the 50-100x gap CLOSED

## THE BREAKDOWN (73 live ASes, 64GiB guest, sb=16G) - ALL THREE prior hypotheses REFUTED as dominant:
  (a) arena COW faults      289 MB total  (~4.0 MB/backend)   1.6%
  (b) page-table clone       81 MB total  (~1.1 MB/backend)   0.4%
  (c) privatized stacks      72 MB total  (~1.0 MB/backend)   0.4%
  (NEW) OVERFLOW COMMIT  17,886 MB total  (~245 MB/backend)  99%   <-- DOMINANT
  TOTAL per-backend        247 MB
Also CONFIRMED: cowmmap ~= 0 (shared_buffers IS correctly shared, not COW-duplicated) AND
range_is_wholly_shared/OSV_FORK_LARGE_SHARE already keeps writable MAP_SHARED 2MB pages verbatim - so the
feared split_large_page-per-fork hugepage regression is ALREADY CLOSED on this base (my concern, refuted).

## THE FIX (gh-fork/bank/fork-footprint-reduction @ 1f277a56d): per-AS DISJOINT overflow VA windows
Carve slot 97 into one 2GiB window per AS slot (256 windows, static_assert'd, tiling with no gap/overlap).
That restores VA->owner arithmetic FROM BSS ALONE: (va - ovf_slot_base)/ovf_window_sz IS the owning slot.
So free() decides same-AS vs foreign WITHOUT READING THE ARENA PAGE - C2-safety preserved EXACTLY (foreign
free stays an unconditional no-op) while the OWNING AS recycles via its normal per-class free-list.
Root cause it fixes: g_bump is a GLOBAL 512MB bump shared across ALL ASes -> at ~74 backends it is ~7MB
each and exhausts immediately -> every later alloc went to fresh per-AS 1MiB mmap_populate regions with
free() an unconditional NO-OP = ZERO intra-lifetime recycling = committed RAM tracked LIFETIME MALLOC CHURN
(PG churns MemoryContexts per query with a small live heap = the pathological case). Now it tracks LIVE HEAP.

## THE MATCHED A/B (same script, same 73 ASes, one build per arm, compile-time switch):
  per-backend private   BEFORE 247 MB   -> AFTER 10.0 MB   = 24.7x reduction
  overflow live         BEFORE 17.5 GB  -> AFTER  283 MB   = 63x
  memfree               BEFORE 29.3 GB  -> AFTER 46.8 GB   = +17.5 GB
  AFTER served 1,512 GB of cumulative churn out of 283 MB live overflow (recycling demonstrably works).
*** 10.0 MB/backend is INSIDE Linux's 5-15 MB band: the 50-100x per-backend gap is CLOSED, not dented. ***
Implication for the practical ceiling: at ~10MB/backend a 64GiB guest should support HUNDREDS of backends
(vs ~74). The max-backends-before-OOM sweep is the headline number still to land.

## *** CAMPAIGN-WIDE CAVEAT DISCOVERED (HIGH PRIORITY) ***: --env= DOES NOT REACH getenv() in this image.
Boot line carried OSV_FP_PROBE=1 but parse_options never printed "Setting in environment" and EVERY
FORKFLAG line read "unset, default" - INCLUDING OSV_FORK_RANGE_BS and OSV_FORK_LARGE_SHARE. Separately,
debugf output never reaches the console (core/debug.cc:167 gates console::write on `verbose`).
CONSEQUENCES: (1) the prior footprint attempt's probe could never have printed anything; (2) ANY past
campaign A/B whose two arms differed ONLY by an --env=OSV_* knob was comparing the COMPILED DEFAULT against
ITSELF = NULL BY CONSTRUCTION. Affected results to AUDIT (not assume): OSV_ZIL_HIRES_CV (#1505 "A/B null"),
OSV_BLK_MQ_COMPLETE (#1509 "HammerDB null"), OSV_WAKE_PULL (#1472 "+238% VU64"), OSV_ZFS_ARC_MAX (#1506 -
the a2a "matched 32GiB ARC both sides" claim!), OSV_IDLE_SPIN/ADAPTIVE (#1501/#1511 - though the gates
agent DID console-verify the lever value per arm, so likely sound).
MITIGATION THAT LIMITS THE DAMAGE: several knobs were deliberately flipped to COMPILE-TIME DEFAULT-ON
during the campaign (#1472, #1509), so the SHIPPED behavior is what was measured; the damage is to the A/B
DELTAS (some may be null-by-construction), not necessarily to the shipped defaults. Also the cwwake
MEMPROBE measured arc_c=2047MB (far below both the 32G cap and the 63G default) so ARC was bounded by
something - needs checking, not assuming.
ACTION (queued, NOT for this agent): a systematic audit of every OSV_* env-gated A/B result for whether the
arms ACTUALLY differed (console-verified lever value per arm, or a compile-time switch). Fix the env plumbing
(--env -> getenv) and/or convert bench A/B knobs to compile-time switches + always print the resolved value
to the console. THE STANDING RULE GOING FORWARD: an A/B is only valid if the lever's RESOLVED value is
printed and verified per arm (the gates agent's practice), never assumed from the command line.

## FINAL RESULT (agent c1991ff6 completed; boxes terminated, 0 orphans, 0 volumes - verified)

### THE HEADLINE (the practical number the operator asked for):
  MAX BACKENDS: ~74  ->  **576**, and it stopped at max_connections=600 with **42.4 GB STILL FREE**.
  The memory ceiling was NEVER REACHED -> 576 is a FLOOR, not a ceiling. The practical blocker is GONE
  (a 64GiB guest now supports hundreds of PG backends, like a Linux host of the same size).

### VU32 (#2): a CLEAN SPLIT, with a mechanism - the footprint is NOT the VU32 gap.
  10,128 vs 10,171 tps (+0.4% = noise) AND ovflive_MB=0 in BOTH arms: at 32 clients the overflow path is
  NEVER ENTERED, so there was no memory pressure to relieve. => the VU32 median gap is a DISTINCT
  throughput factor, cleanly separated from the footprint. (Good: it rules the footprint out with a
  mechanism, not just a null.) The VU32 gap remains OPEN and unexplained - a separate investigation.

### HONEST GAPS the agent flagged (do not paper over):
 1. The BEFORE crash was a STACK-OVERFLOW signature with 29GB free - NOT the documented OOM. So the
    BEFORE failure mode at high backend count may be a distinct bug (stack exhaustion), not only the
    footprint OOM. Worth a look.
 2. The matched BEFORE max-backends sweep was LOST to a checkpoint wedge -> ~74 remains the EARLIER
    campaign's number, not re-measured in this matched run. So "74 -> 576" mixes a prior-run BEFORE with
    this-run AFTER. The AFTER (576, 42.4GB free) is solid; the BEFORE is inherited.
 3. No HammerDB VU64/128/192 in this run (the scaling re-test at realistic shared_buffers is still owed).

### BANKING HYGIENE TO FIX BEFORE ANY PR: 4 of the 5 commits on bank/fork-footprint-reduction are
### UNSIGNED (%G? = N), including the fix itself (1f277a56d); only 95fd7385b is G-signed. The campaign
### convention is -S signed with %G?==G. Before this becomes a PR: re-commit/sign the series, and SPLIT it -
### the FIX (1f277a56d, the per-AS overflow windows + owning-AS recycle) is the shippable change; the probe
### commits (95fd7385b, 3b1b3829a, 9a611512a, d994a616c) are instrumentation/debug and should NOT ship
### (or ship separately as a debug facility). Also the fix stacks on the fork stack, so it lands with that
### series (S8 area), not direct-to-master.

## STILL OPEN / QUEUED FROM THIS RUN:
 - the --env=/getenv audit (HIGH PRIORITY, see above) + the unexplained missing "Setting in environment"
   install line (the agent noted ordering explains the probe latching off but NOT the missing install line -
   "that half is unexplained and worse").
 - debugf is verbose-gated (core/debug.cc:167) - a standing trap for any future probe; use debug_early.
 - the VU32 distinct throughput factor (now cleanly isolated, still unexplained).
 - the BEFORE stack-overflow-at-high-backends signature (possibly a separate bug).
 - HammerDB VU64/128/192 at realistic shared_buffers with the footprint fix in.

## TASK #2 DONE (2026-09-19): series RE-SIGNED. bank/fork-footprint-reduction-signed @ 1480fbee1 - all 5
## commits %G?==G, tree BYTE-IDENTICAL to the original (verified: same tree hash ce1da8b8..., empty diff).
## Pushed to a NEW branch; the original bank/fork-footprint-reduction is preserved untouched.

## THE PROBE/FIX SPLIT: DEFERRED to PR time, WITH a compile check. Why deferred (honest): I cannot
## compile-verify a hand-strip locally (no toolchain on this host; the agent built in an on-box container).
## Hand-editing C++ I cannot build and pushing it as "the clean PR" risks a broken branch - worse than
## leaving small counters in. So I re-signed (verifiable, zero code risk) and documented the exact strip:
##  FIX-ESSENTIAL (keep): the per-AS disjoint overflow windows (ovf_window_sz, ovf_owner_slot), the
##    owning-AS recycle in free(), the OSV_FORK_OVF_RECYCLE gate, and `ovf_mapped` (this is the per-AS
##    window bump CURSOR the allocator needs - it LOOKS like a probe counter but is load-bearing).
##  PROBE-ONLY (strip at PR time, with a build check): `g_ovf_recycled` (pure counter, written at :588,
##    read at :338), `overflow_stats()` (:334-350, the accessor), and the FOOTPRINT PROBE comment blocks.
##    Also pre-existing base cruft to strip: `leak_probe_stats` (fork_arena.hh:107, 0 callers).
##  The 4 probe commits (da8f1ef61 OSV_FP_PROBE, a7d691faf loader probe-start, a3a305b11 compile-time A/B,
##    1480fbee1 debug_early) should NOT ship as-is; either drop them or land the probe separately as a
##    debug facility. The FIX commit is 340ef4f92.
##  The fix STACKS on the fork series (S8 area per the #1458 proposal), NOT direct-to-master.
