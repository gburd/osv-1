# IDLE-SPIN (#1476 / OSV_IDLE_SPIN) reconciliation - LOCAL, no rerun, no EC2

Copyright (C) 2026 Greg Burd

QUESTION: #1476's perf claim is contradicted. The original A/B (TAIL-DIAGNOSIS) showed RO c32
+11% / RW +55%; the later native-a2a 500x sweep (NATIVE-TAIL STEP 4) showed 0% (null). Reconcile
WITHOUT a rerun and give a #1476 disposition.

## The two runs, side by side (from the banked results)

### Run A - TAIL-DIAGNOSIS.md (agent osv-struct) - the +11%/+55% claim
- Build: wip/pg-tail-fix, conf_fork=1 **fs=ramfs** image=postgres18-musl.
- Host/hypervisor: **qemu 8.1.3** KVM, single-queue vhost, smp16, NUMA-clean node0 guest.
- A/B: OSV_IDLE_SPIN **10000 -> 100000 (10x)**, median-of-3, 0-failed.
- OUTCOME: RO c16 +7% / c32 +11% / c48 +17% / c64 +20%; RW c32 +55%. c1/c8 unchanged.
- MECHANISM (the smoking gun): halt_exits/s c32 **48975 -> 434 = 99% COLLAPSE**; halt_poll_ok
  tracks. i.e. the guest-side spin DID skip the halt VM-exit.

### Run B - NATIVE-TAIL-RESULT.md STEP 4 (agent osv-native-tail) - the null
- Build: wip/pg-tail-fix + 2 nitro cherry-picks, conf_fork=1 **fs=ramfs** image=postgres18-musl.
- Host/hypervisor: **qemu (a later build, 9.x-era per the run's tooling)** KVM, smp16, @ c32 only.
- A/B: OSV_IDLE_SPIN **10000 -> 200000 (20x) -> 5,000,000 (500x)**, 3 rounds each.
- OUTCOME: tps 0% change, exits/s 0% change across all three spin values.
- MECHANISM: halt_exits/s **57692 -> 58084 (UNCHANGED)** - the guest-side spin did NOT collapse
  halts. halt_poll_ok ~46k of ~58k halts already caught by KVM's OWN adaptive halt-polling.

## What is (and is NOT) the difference

NOT the difference: fs (both fs=ramfs, so this is NOT a ramfs-vs-zfs artifact), NOT concurrency
(both smp16 c32), NOT the workload (both PG18.6-musl pgbench), NOT the base branch (both
wip/pg-tail-fix). The A/B methodology matched (median-of-multiple, 0-failed).

THE DIFFERENCE is a single measurable mechanistic fact: **did the guest-side spin collapse the
halt VM-exits?**
- Run A: YES (48975 -> 434). And tps rose.
- Run B: NO  (57692 -> 58084). And tps did not move.

Both runs are INTERNALLY CONSISTENT: tps moved IF AND ONLY IF halts collapsed. The mechanism and
the outcome agree WITHIN each run. The disagreement is entirely upstream of tps: whether the same
env knob collapses halts on that host/qemu.

## Why the SAME knob collapses halts in A but not in B (best explanation, no rerun)

The mechanism the spin competes with is **KVM's own adaptive halt-polling** (host-side): when a
vCPU issues HLT, KVM spins in the host for a short adaptive window before de-scheduling it, so a
soon-arriving wake is caught WITHOUT a full de-schedule/re-schedule. Two mechanisms are racing to
catch the imminent request: the GUEST's do_idle spin (OSV_IDLE_SPIN) and the HOST's KVM
halt-poll. Whichever fires first wins.

- If the guest spin is calibrated so a backend catches the next request BEFORE it ever issues HLT,
  the halt_exit never happens -> Run A's 99% collapse.
- If KVM's host-side halt-poll window is wide/aggressive on that qemu/kernel, it ALREADY catches
  the same imminent wakes (halt_poll_ok ~46k of ~58k in Run B), so the guest spin has nothing left
  to collapse - a longer guest spin only burns guest CPU with no exit-rate change -> Run B's null.

qemu 8.1.3 (Run A) vs the later 9.x-era qemu (Run B), and any difference in the host kernel's
`halt_poll_ns` default/adaptive tuning, changes which mechanism wins. This is the classic
"guest-side spin-before-halt is redundant with host-side halt-polling" outcome: it helps exactly
when the host is NOT already halt-polling those wakes, and is null (pure CPU burn) when it is.
Run B even states this directly: "KVM's OWN adaptive halt-polling already catches most halts; a
guest-side spin cannot reduce exits KVM already avoids."

A secondary, compounding factor: Run A's win GREW with concurrency and was largest on RW (+55%),
where backends block longest (fsync/WAL) and the imminent-request window is longest / most
catchable by a guest spin; Run B measured only RO c32, the very cell where Run A's RO win was most
marginal (+11%) and most sensitive to the host halt-poll race.

## Is the mechanism real but tps-neutral because tps is bottlenecked elsewhere?

Partly YES, and this is the honest core of it. Even in Run A where halts collapsed 99%, RO c32 rose
only +11% and the plateau stayed at ~0.5x of Linux - because the tps ceiling is NOT the halt exits
alone. The read path (ZFS-READPATH-CODESTUDY.md: the per-vnode v_lock serialization + the per-read
copy) and the process-per-connection wake floor (WAKE-INLINE-RESULT.md) set the real ceiling. So:
collapsing halts removes ONE VM-exit per blocked request (a genuine efficiency gain), but the
end-to-end tps only moves a little, and only when the host halt-poll wasn't already collapsing
those halts. When the read path or the wake floor dominates a cell, halt-collapse is invisible in
tps even if the mechanism fires.

## VERDICT on #1476's perf claim

**REAL-BUT-MARGINAL AND HOST-CONDITIONAL.** The mechanism (collapse the per-request halt VM-exit)
is real and was directly measured (99% halt-exit collapse, Run A). But its END-TO-END tps benefit
is:
- conditional on the host NOT already halt-polling those wakes (null on the Run B host/qemu),
- small even when it fires (+7-20% RO, and the RO mid-range +20% did NOT survive median-of-3 in a
  later wake-inline A/B either), with the one robust cell being RW / the deep tail where backends
  block longest,
- and always a CPU-burn cost on a busy host.

It is NOT a clean uniform RO win and it is NOT null-everywhere - it is a halt-exit efficiency lever
whose tps payoff depends on the host's halt-poll behavior and is capped by the read-path + wake
floor that actually set OSv's tps ceiling.

## #1476 DISPOSITION RECOMMENDATION => (b) REFRAME as "reduces per-request halt VM-exits,
##                                        perf-neutral-to-marginal", keep as an honest efficiency
##                                        change, still DRAFT.

- Do NOT withdraw (c): the mechanism is real, the code is correct, default-off/byte-identical when
  OSV_IDLE_SPIN is unset, and it is a legitimate generic efficiency knob for a
  request/reply one-process-per-connection server on a hypervisor whose halt-polling is not already
  catching the wakes. Withdrawing throws away a real, correctly-implemented lever.
- Do NOT keep the current perf-claiming framing pending a "clean rerun" (a): a rerun cannot
  produce a stable universal number - the result is host/qemu-halt-poll-dependent BY CONSTRUCTION,
  so re-running will just reproduce "sometimes +X%, sometimes null." Chasing a single headline
  number here is a wild goose chase.
- DO reframe (b): change the PR body from a throughput claim to the honest mechanism claim -
  "makes the idle spin-before-halt budget env-tunable; a longer budget can catch an imminent wake
  in the guest and skip the halt VM-exit round-trip, reducing per-request halt exits on hosts whose
  hypervisor halt-polling does not already catch them; default unchanged (byte-identical)."
  Frame it as an efficiency/tunability change, not a performance-uplift change. Keep it DRAFT
  (maintainer offline til Nov, one-PR-at-a-time). It is ready-to-flip once reframed.

Generic-framing reminder for the reframed body: request/reply one-process-per-connection server,
halt/wake VM-exit round-trip, env-tunable spin budget, default byte-identical. NO PG/pgbench/
HammerDB/testbed numbers/qemu-version-as-testbed-fingerprint.
