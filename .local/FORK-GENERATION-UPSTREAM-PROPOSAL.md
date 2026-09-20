# Proposal: upstreaming the fork-arena + shared-gfdt fd-table generation (and where the two validated leak fixes land)

Draft for the maintainer (nyh / wkozaczuk) - a composition proposal, NOT a single PR. Ready to convert
into a PR series or a discussion comment on #1455/#1456/#1458 when they engage.

## Why this document exists
Two real, measured, validated OSv platform fixes are DONE and blocked on one thing: they modify code that
only exists in a large, unproposed fork evolution. There is no open PR whose base contains that code, so
they cannot be filed. This proposes how to get that evolution upstream so the fixes (and the evolution
itself, which is independently valuable) can land.

## The situation, precisely
- Open fork PRs today: #1455 (base thread-backed fork/vfork/execve/wait, 5 commits) and #1456 (per-child
  COW address space, 7 commits). These carry the ORIGINAL, simpler fork model.
- The PostgreSQL-on-OSv work evolved a NEWER generation on top of that idea - a ~134-commit body
  (branch reference: the fork-clone-scan lineage) that is a DIFFERENT, more complete fork implementation:
  a COW-private heap ARENA for fork children, a SHARED global fd-table (gfdt) with correct inherited-fd
  semantics, lock-free COW fault handling, IRQ/timer/thread-lifecycle coherence, elf/dlopen sharing, and
  the OpenZFS glue. It is NOT an increment on #1456 (all 134 commits are outside #1456; the fd model
  conflicts with #1456's older one). It currently lives only in the integration stack tracked by #1458
  (DRAFT / DO-NOT-MERGE).
- The two validated leak fixes (below) sit at the TOP of this generation and depend on its arena + gfdt.

## The two validated fixes waiting on this (the concrete payoff)
1. LEAK #1 - fd/gfdt EMFILE leak on backend reap. release_inherited_fds() closed inherited fds but only
   erase()d the tracking for fds a backend opened itself after fork, never closing them in the shared
   gfdt -> gfdt fills to FDMAX -> pipe()/accept() EMFILE -> guest wedges. A/B: 400 rounds, gfdt flat ~30
   (fix on) vs climb-to-65535/EMFILE at round ~224 (off). Review-ready: bank/fork-fd-reap-leak-reviewready.
2. LEAK #2 - fork-arena memory leak. The arena's global bump pointer never returns a reaped child's VA;
   after ~700 backends the arena exhausts and every backend's per-connection heap falls to the identity
   heap, which is never freed on reap -> ~0.85 MB/backend -> OOM. Fix: a per-AS COW-private overflow
   region reclaimed wholesale on reap (no-op free via BSS range-check, never reads a chunk header
   cross-AS), plus scoping 8 cross-AS-referenced kernel objects (socket/inpcb/tcp-timer/net_channel/
   stdio FILE) to the identity heap. A/B: 400 rounds / 26,181 backends, mem_free FLAT (on) vs monotonic
   drop (off), zero corruption, zero cross-AS fault at scale. Banked: bank/fork-arena-real-reclaim.
Both are generic (help any fork-heavy long-running workload; PG is the forcing function), not PG hacks.

## A finding worth surfacing regardless of composition (the masking insight)
The fork arena is COW-mapped in EVERY address space, so a cross-AS raw-pointer access reads a divergent
COW COPY instead of faulting - it SILENTLY MASKS latent cross-AS-correctness bugs. Making per-connection
memory per-AS (the leak #2 fix) turned those into hard faults and exposed 8 pre-existing fork-coherence
gaps (a FILE on the process-global ofl_head list; a net_channel RX-ring written by the AS0 classifier in
IRQ context; etc.). The correct invariant is "cross-AS-referenced objects must live on the identity heap."
An audit of the AS0/IRQ/RCU-touched object graph proved that set is BOUNDED and enumerated it. This means
the arena's mapped-everywhere property may be masking OTHER latent fork-coherence bugs - relevant to how
the fork model should be reviewed.

## Proposed decomposition (a landable series, not one blob)
The ~134 commits group into coherent, independently-reviewable units. Rough shape (commit counts approx):
  S1  fork-arena: COW-private heap arena for fork children (~10)  [the heap-isolation foundation]
  S2  fork COW address-space / clone-range correctness + perf (~10)  [supersedes/extends #1456's AS work]
  S3  timer / IRQ / thread-lifecycle coherence across address spaces (~7)
  S4  elf/dlopen segment sharing across fork address spaces (~7)
  S5  shared-gfdt fd-table: inherited-fd semantics + reap-close (fd model) (~3-5)  [+ LEAK #1 lands here]
  S6  signal routing (self-signal/SIGURG/SIGCHLD to the right AS) (~6)
  S7  the OpenZFS glue that the fork path needs (~40)  [likely folds into #1423's lineage, not here]
  S8  fork-arena overflow reclaim (LEAK #2) + the 8 cross-AS-object scopings (~3)
Order: S1 -> S2 -> S3/S4/S6 (parallel) -> S5 (+leak#1) -> S8 (+leak#2). S7 tracks with #1423.
This is a STARTING decomposition for the maintainer to accept/reshape - the key decision is whether the
newer generation SUPERSEDES the #1455/#1456 model or lands as a stacked successor.

## The single decision that unblocks everything
Does the newer fork generation (arena + shared-gfdt fd-table + coherence) become the proposed fork
implementation (superseding or extending #1455/#1456), and in roughly the S1..S8 shape above? Once that is
decided, S1..S8 open as reviewable PRs and the two validated leak fixes land as their natural commits in
S5 and S8. Everything is already built, G-signed, and (for the leaks) A/B-validated at scale; the blocker
is purely this composition call, which only the maintainer can make.

## What we are NOT claiming
We have NOT proven OSv-vs-Linux PG PARITY. We removed the known wedges/leaks and refuted the "OSv
declines" curve as a run-order artifact, but the clean fresh-boot-per-cell a2a comparison on the
projected-merged base is UNRUN. A separate, still-open factor is the per-commit recycle-latency / wakeup
deficit (OSV_IDLE_SPIN closes the isolate; HammerDB transfer unproven). Parity is an open measurement.

## Pre-PR cleanup (noted, cheap)
Strip the pre-existing leak_probe_stats() debug helper from the shared base before S1/S5/S8 open (it is
base cruft on the leakhunt lineage, 0 callers, not part of any fix).
