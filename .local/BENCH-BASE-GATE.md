# Benchmark base gate: never spend a box on a base missing a required fix

## Why this exists (the mistake it prevents)
The a2a-all-levers base was assembled from "the fixes I was actively working" (fsync #1507, wake-pull
#1472) plus whatever cbbf74e7 happened to carry (TCB #1504, ZIL #1505). It SILENTLY OMITTED #1502 (the
dentry AB-BA lock-order fix). #1502 removes a DEADLOCK that wedges the guest at VU32, so the run could
never complete VU32/64 - it capped the scaling sweep and could not answer the scaling question. That is
wasted hours + money, caught only after the run wedged.

Root cause: the fix set was an act of MEMORY, not a CHECKLIST. #1502 was filed and MERGEABLE the whole
time. No gate existed to catch the omission.

## The gate: .local/bench-base-gate.sh
Run against the OSv source tree the image will be built from:
    sh .local/bench-base-gate.sh <tree-root>
Greps a required marker for each fix; exits non-zero and names the missing PR if any is absent.
REQUIRED (gated): #1504 TCB, #1505 ZIL hires, #1472 wake-pull (code + default-on), #1507 fsync guard,
#1502 AB-BA lock-order, fork RANGE_BS + LARGE_SHARE.
OPTIONAL (reported, not gated): #1503 per-chain locks (throughput-null, does not fix the deadlock),
#1506 OSV_ZFS_ARC_MAX (situational - match ARC on either side).

Verified: FAILS bench/a2a-all-levers (names #1502, exit 1); PASSES bench/a2a-shape-fix (exit 0).

## Standing rule for EVERY benchmark run (and every benchmark agent brief)
Before building a benchmark image, run bench-base-gate.sh on the source tree and REFUSE to launch a box
if it fails. Agent briefs must include: "run .local/bench-base-gate.sh on the built source; if it exits
non-zero, do NOT launch - report the missing fix." This makes the fix set enforceable, not remembered.

## Maintaining the registry
When a new merge-eligible OSv-side fix lands that affects PG-at-scale, ADD a check row to
bench-base-gate.sh with its grep marker and a one-line "why it matters". The gate is the single source
of truth for "what a full-scale PG base must carry".
