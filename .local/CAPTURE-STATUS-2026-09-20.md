# Capture status (2026-09-20) - everything banked in code, PR notes, and pushed branches

## NOTES: the full analytical record is now DURABLE ON BOTH MIRRORS (was a single-host risk)
notes/pg-campaign-record @ 1398cc43e on origin (codeberg, private) AND gh-fork. 1568 files / 107,505 lines,
G-signed, based on upstream/master (clean apps gitlink - the stale wip branch's dangling 57c6079843 pin was
correctly REJECTED by the pre-push hook, which is why it went on a master base instead).
Contains: every measured verdict, every REFUTED hypothesis retracted in place next to the evidence that
overturned it, the harness scripts + per-cell evidence so any published number is traceable, and the
standing methodology rules. Excludes worktrees/build trees (notes + scripts only, 5.1MB of content).

## CODE: upstream vs banked
UPSTREAM (direct-to-master, NOT fork-blocked) - the scaling arc's shippable yield:
  #1511 sched: adaptive per-CPU idle-spin window (supersedes #1501) - awaiting first review
  #1512 bench: durable-write syncwrite isolate (the instrument behind #1511's table - makes it reproducible)
  #1464 sched: load-balancer disperse (APPROVED + CLEAN + MERGEABLE = one click)
  #1472 sched: idle-CPU pull work-stealing | #1480 condvar lock-before-waitqueue | #1484 null-thread wake
BANKED, validated, blocked ONLY on the #1458 fork-composition keystone:
  bank/fork-fd-reap-leak-reviewready   leak #1 (fd/gfdt EMFILE), 400-round A/B
  bank/fork-arena-real-reclaim         leak #2 + 8 cross-AS coherence scopings, 5-gate validated
  bank/fork-footprint-reduction-signed footprint fix (247->10MB/backend), all 5 commits G-signed
  (pre-PR: strip the probe-only bits WITH a build check; KEEP ovf_mapped - it is the fix's window cursor)

## PR NOTES: posted upstream 2026-09-20 (#1458 comment 5749965679)
The footprint root-cause + fix + the scaling verdict + the write-completion finding, written in GENERIC
terms (any forked child that allocates/frees over its lifetime; PG is just the fastest way to hit it), with
the measured tables, the refuted-hypotheses note, and a pointer to #1512 for reproducibility. Leak-scanned
(no box ids/IPs/accounts) before posting publicly.

## THE GENERIC-NOT-PG-SPECIFIC FRAMING (the operator's standing requirement - honored)
Every banked fix is a generic OSv defect or improvement, and the PR notes say so explicitly:
 - leak #1: a shared-fd-table reaper released only the inherited half; any fork-heavy process leaks fds.
 - leak #2 + the footprint fix: a forked child's committed memory tracked lifetime allocation CHURN, not
   live heap; any forked child that allocates and frees over time pays it.
 - the 8 coherence scopings: cross-address-space-referenced kernel objects must live on the shared heap -
   generic fork correctness (the arena was MASKING these by serving divergent COW copies).
 - #1511 adaptive idle-spin: a fixed spin count is the wrong control for halt-vs-poll; any cross-vCPU
   wakeup-heavy workload benefits.
 - #1512: a measurement, no behavior change.
PostgreSQL is the forcing function and is named as such, never as the justification.
