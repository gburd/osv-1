# Queued follow-ups (from the 2026-09-16 maintenance sweep triage) - not blocking, not maintainer-gated

## CAN-DO (proactive, need EC2 or code work):
- **C. native-ZFS 4a is SUPERSEDED - RETIRED (updated 2026-09-17).** The prior "validate + open 4a"
  action is WRONG and withdrawn. Direct diff comparison shows OPEN PR #1478 ("enable a runtime ZFS data
  pool on a non-ZFS-root image", non-draft, MERGEABLE, merge-clean) already carries 4a's exact
  zfsdev_init() change as its change #1, PLUS the four pieces 4a lacks and needs to actually work:
  RTLD_GLOBAL (nvpair symbol resolution), /etc/mnttab, MOVING the preload before the root-mount pivot
  (4a leaves it after, which #1478's comment documents as the reason a late preload FAILS), and the
  manifest+ZIL fixes. Standalone 4a would be a strict subset AND non-functional. Do NOT open it; 4a lands
  via #1478 (maintainer-gated merge). wip/native-zfs-fixes commit 59f4f12ad = retired.
- **D. Fold 4b RDSEED into #1492** (commit 1600b68cb reworks the same drivers/random.cc early-read path #1492
  touches, adds RDSEED - 21 refs). Do NOT open as a competing PR. Fold the RDSEED delta into #1492 or a
  follow-on stacked on it, AFTER #1492 review settles (avoid colliding with in-flight review).
- **E. Rebase NUMA family (#1438/#1441/#1445) onto master's new SRAT/SLIT layer** - substantive rebase
  (master gained a SRAT/SLIT layer; these conflict there). Do when picking up the NUMA thread; not urgent.

## MAINTAINER-GATED (nothing I can do while nyh offline - do NOT nudge):
- Clear #1439 stale CHANGES_REQUESTED (all points answered; only the maintainer clears a review flag).
- Merge order when maintainer returns: #1464 (APPROVED) + #1502/#1503/#1504 (clean, non-fork) first, then
  #1488 (OpenZFS 2.4.4) + #1500 (lwext4 pin), then #1449 (security), #1500 area. #1455/#1456 fork
  composition = maintainer decision.

## CORRECTED THIS SWEEP:
- OpenZFS: we are on 2.4.3, NEWEST is 2.4.4 (2026-08-21) which is PREPARED in open #1488 (merge-clean,
  maintainer-gated). The earlier "on 2.4.4" claim was wrong - PROGRAM-STATE corrected.
- lwext4: master unpinned; #1500 pins to current fork tip (6f6d8f7c), merge-clean.
- Only ONE upstream filing exists: lwext4 #100 (open, dormant since 2026-07-14, non-blocking). Zero
  OpenZFS filings by us.
- upstream/master UNMOVED at 0e34e4dc2 (since 2026-08-17); 48/56 open PRs merge-clean; conflicts are
  pre-existing base-drift (NUMA family + fork-stack), not new.
- osv-apps at 3f93f43 = #73's exact pin (current); 0 unanswered reviewer comments across all 56 PRs.
