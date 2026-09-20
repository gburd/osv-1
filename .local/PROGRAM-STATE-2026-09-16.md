# Program state 2026-09-16: M1 investigation concluding; broader program banked.

## The M1 verdict is the ONE measurement still running (agent ccc5615b, agent-spinverdict).
OSV_IDLE_SPIN HammerDB sweep on a clean apps@3f93f43 base (seed hygiene fixed - the prior EACCES was
the wrong apps pin 5cb1903, not a seed_copy bug; the agent's build.sh re-pins to 3f93f43). Answers:
does the isolate win (+56-140% durable-write op/s, OSv>=Linux) TRANSFER to TPROC-C, or does idle-spin
steal query cycles? Either answer CONCLUDES the M1 deep-dive definitively.

## M1 deliverable: DONE regardless of the verdict - the gap is FULLY EXPLAINED.
.local/M1-FIX-LEDGER.md (written by the maintenance sweep) is the writeup: root cause = OSv cross-vCPU
WAKEUP LATENCY (IPI-to-halted-vCPU VM-exit), surfacing as wedge/fan-out/completion/ZIL-recycle; same
upstream zil.c single-committer model as Linux; Linux builds depth via cheap wakes, OSv stays shallow
because each recycle eats a wake VM-exit; OSV_IDLE_SPIN attacks the wake half (isolate CLOSED, HammerDB
pending). Six hypotheses refuted by measurement. 11 fixes + 1 bench lever tabulated with measured effect.

## 11 fixes banked (all master-facing, generic G2, honestly scoped):
FILED open+clean: #1502 dentry AB-BA (e2e), #1503 per-chain, #1504 TCB psABI, #1505 ZIL hires,
  #1506 ARC-max, #1507 fsync scan (NOPM-null), #1508 physio per-iovec, #1509 per-queue completion
  DEFAULT-ON (isolate +2.1x, HammerDB null), #1472 wake-pull default-on.
FILED draft: #1510 ext4 read-ahead (needs re-measure), #1501 idle-spin (isolate +56-140%, HammerDB
  unverified - the verdict run may un-draft it).
None claimed as M1 parity; each stands on its own defect/improvement merit.

## Program hygiene (maintenance sweep 2026-09-16):
- 0 unanswered reviewer comments across all 56 PRs (both APIs, no new human activity since 09-14).
- #1464 APPROVED (waiting maintainer); #1439 stale-CHANGES_REQUESTED.
- Deps: master OpenZFS pin = branch zfs-2.4.3 (gitlink 83020cf8, released 2026-06-12); newest upstream
  release is zfs-2.4.4 (2026-08-21) and it is ALREADY PREPARED in OPEN PR #1488 (pinned to the exact
  zfs-2.4.4 tag commit 71a9f957, merge-clean, not draft). So master is one release behind; #1488 catches
  it up. [CORRECTED 2026-09-16 maint sweep: the earlier "OpenZFS 2.4.4" claim was wrong - that is the
  pending #1488, not master's pin.] lwext4: master's Makefile does a floating `clone --depth 1` (no pin);
  OPEN PR #1500 pins it to 6f6d8f7c = the CURRENT tip of osvunikernel/lwext4 master (2025-07-04),
  merge-clean, a no-op on bits. Master unmoved 0e34e4dc2 since 2026-08-17.
- No new upstream-elsewhere activity. ~987MB /tmp scratch reclaimed. Worktrees 15, all load-bearing.
  0 EC2 orphans. The untagged 20GB vol is GONE (cleaned since 09-14).

## Remaining work (ranked, maintainer/next-phase):
1. Merge #1502/#1503/#1504 + #1464 (APPROVED) - all clean, non-fork-gated - MAINTAINER offline.
2. Clear #1439 stale flag - MAINTAINER.
3. OSV_IDLE_SPIN HammerDB verdict (IN FLIGHT) - un-drafts #1501 if it transfers.
4. ext4 re-measure -> un-draft #1510.
5. #1455/#1456 fork composition - MAINTAINER decision.
6. M2 (PGXN: every extension works OSv==Linux) - NOT STARTED. The next major phase once M1 concludes.

## Honest overall: M1 parity not demonstrated, but fully characterized to a single root (wakeup latency),
## with 11 real upstream fixes and one candidate lever (OSV_IDLE_SPIN) whose end-to-end transfer is the
## last open measurement. The bulk of the deliverable (root cause + fixes + writeup) is BANKED. Whether
## M1 "closes" hinges on the verdict; if it does not, the honest conclusion is OSv's wakeup-latency
## profile needs broader scheduler work than a single knob, and M2/PGXN is the next phase either way.

## Focused gap-sweep (agent 107715f8, 2026-09-16) - actionable items closed, not a re-verify:
- GAP1 features: NOTHING unblockable to file/un-draft. #1459/#1478/#1488 already open+clean+non-draft.
  Drafts (#1510 #1501 #1487 #1455 #1444 #1445 #1475 #1458) each listed with exact blocker; the 3
  stacked-draft merge-tree "conflicts" are just unmerged bases (expected). No PR opened (bar not met).
- GAP2 #1439: re-walked both APIs - NOTHING substantive unanswered (nyh's 2 points + 7 Copilot all
  addressed; SIGKILL/SIGSTOP filtered via sigdelset verified in head). No nudge (maintainer offline).
- GAP3 #1458 BODY EDITED: it listed #1423 + #1457 as still-to-merge blockers; BOTH merged (#1457
  2026-08-03, #1423 2026-08-17). Corrected to mark them MERGED, split now blocked only on #1455/#1456.
  Verified: #1423 + #1457 are genuinely MERGED. No other draft body/commit-msg carries a stale claim.
- GAP4 osv-apps: #73 head 3f93f43 (seed_copy fix) STILL CURRENT; osv-apps diverged 6-ahead/4-behind but
  the 4-behind touch NO postgres18-musl files -> clean future rebase, seed_copy fix intact. #71 idle.
- Tidy: removed 1 new scratch (/tmp/seed-ramfs.sh); left /tmp/kq.fix (XTC project, not ours). Worktrees
  15 all load-bearing. EC2 0 OSv orphans (spinverdict active, untouched; larql not ours).

## memelord RECOVERED this turn - 2 top lessons FILED (4+ sweeps could not during the outage):
  c3d63cc4 = M1 root cause (OSv cross-vCPU wakeup latency, discriminator method, 6 refuted hypotheses).
  482b4cbb = substrate/methodology directives (Debian-not-AL2023, projected-merged base+gates, one-var,
             seed apps-pin 3f93f43, raw-NVMe-passthrough, LaunchTime-gated tidy).

## Net: program is CLEAN and CURRENT. Only actionable maintenance item this turn was the #1458 body
## correction (done). Everything else is maintainer-gated (merge #1502/#1503/#1504/#1464, clear #1439)
## or benchmark-gated (M1 verdict in flight, ext4 re-measure for #1510). M2/PGXN is the next phase.
  spinverdict: pipeline works, VU16 baseline 119419 NOPM, primary spin-sweep running

## M1 verdict early cells (agent ccc5615b, spin sweep):
  VU16 spin=10000: 109k/159k/125k  spin=100000: 169k/43k  -> ~4x variance, NOISY, NOT the verdict cell.
    (VU16 ~120k already near/above earlier Linux; spin effect drowned in noise. The 43k = a slipped-
     quiesce/cold cell.)
  VU32 spin=10000: 9328/8535/9336 -> TIGHT ~9,300 NOPM = a REAL 13x COLLAPSE from VU16. This IS the M1
    decline, and VU32 is THE verdict cell.
STEERED: prioritize VU32 spin=100000 + spin=500000 (3 settled each) + mpstat. The verdict:
  - VU32 jumps ~9k -> 100k+ with spin -> OSV_IDLE_SPIN RESCUES the decline, transfers, M1 CLOSING.
  - VU32 stays ~9k -> does NOT transfer to TPROC-C, honest null (isolate-only win).
  - mpstat on VU32: useful PG work vs spin-cycle theft. Tighten quiesce (2 sub-1s cp, void cold cells).
The ~9k VU32 baseline triplet is tight = clean measurement there; the spin-rescue cells are the answer.
