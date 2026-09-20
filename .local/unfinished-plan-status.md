# Unfinished plan -- status snapshot 2026-08-15 (re-verified 2026-08-15T13:02Z sweep)

Source: ROADMAP.md + live PR states. Upstream master af96db0f7 (unchanged).
25 open PRs (was 24; +1 = the ld-musl PR #1473 opened by the concurrent
banking agent, not this sweep).

## Scale / fix-chain progress (benchmark + banking agents, gh-fork branches)
- The PG-on-OSv scaling problem is LARGELY solved for the mid-range: the fix
  chain (integ/pg-fork-zfs -> cow-fork-irq-fix -> pg-scale-fix (fd-table) ->
  pg-mq-scale (MQ+RSS, +25%) -> pg-scale2 (idle-CPU PULL + parked-timer-unlink))
  took OSv from "peak c8 then collapse to 0.23x" to "climb to c8, plateau, c32
  ~0.62x RO, RW wins every cell", 0-failed c1-c64. More vCPUs now help (smp16
  +16-21% over smp8). Residual gap to Linux = the fork-per-backend structural
  cost, documented as the next architectural lever (not a serialization bug).
- Candidate upstream PRs from the chain: MQ (#1463 substrate, DRAFT), RSS
  (#1470, DRAFT), the ld-musl soname fix (#1473, opened by the banking agent),
  the parked-timer-unlink (sched correctness, generic). The concurrent banking
  agent is promoting #1463/#1470 and opened #1473; NOT touched by this sweep.

## Fork trilogy gate
- **#1455** fork()/vfork()/execve()/waitpid() -- OPEN, still NOT merged (last
  reviewer activity 2026-08-04). THE GATE. #1456 (per-child COW AS), #1458
  (PG+ZFS integ, DRAFT), #1459 (openzfs aarch64, DRAFT) stay blocked behind it;
  #1424 (Crucible, DRAFT) stays blocked on #1423. Maintainer-gated, no
  self-serve action.

## OpenZFS keystone
- **#1423** `zfs: selectable in-kernel ZFS (BSD or OpenZFS 2.4.x)` -- OPEN,
  not-draft. **RESTRUCTURE LANDED ON THE PR HEAD + KVM-VALIDATED**: a focused
  session forward-ported the restructure onto the live PR (head now
  `6c4c39bb6`, 29 commits, ff/additive -- no history rewrite): `7940379c`
  relocate the OSv platform layer to real source + shrink the patch series to
  one, `6c4c39bb` fix three include-resolution defects the relocation exposed.
  The 08:58Z validation comment states the result is build+boot+pool-mount
  qualified against a real KVM host. Two decisions still awaiting a maintainer
  reply (posted 07:06Z/08:58Z, no wkozaczuk response as of 13:02Z): the failing
  openzfs unit-test disposition (fix-if-small else documented-gap + tracking
  issue) and squash-to-one-commit / drop DRAFT-BLOCKED banner. Local staging
  worktree wip/openzfs-restructure @ 6c4c39bb6 matches the PR head exactly.
  Still pending pre-merge: squash, drop banner, ZFS tests -> standalone
  tests += (#1469), tracking issue for the failing unit tests.

## Crucible
- **#1424** `[BLOCKED] Crucible distributed block driver` -- DRAFT, CONFLICTING.
  Blockers #1398 + #1400 now MERGED, but **still blocked on #1423** (needs the
  OpenZFS root). No action until #1423 lands.

## M2 / PGXN
- Not represented by an open PR yet. PG-on-OSv milestone work (PGXN packaging)
  is downstream of the fork trilogy + #1423 both landing; not startable now.

## Fork-timer / parity work IN FLIGHT (benchmark agent, osv-forktimer-decide)
- The central open bug: shipped-OSv asserts at smp>=2 on the first forked PG
  backend -- `assert(preemptable())` in timer_list::fired() on the COW-fork path
  (ROADMAP: the IRQ-context-COW-timer-in-foreign-AS disease). Root-caused in
  tst-fork-irq-cow.cc; fix exists (2d218bd3f park-timers + 9108df4b5) but may be
  INCOMPLETE. The running agent (32f6edb5-class) is deciding contamination-vs-
  real-bug and, if the fix is incomplete, completing it, then running the
  vCPU-matched fair benchmark. This gates ALL multi-vCPU serving + the honest
  parity number. Also open: the dmu_objset_own ENXIO fork-ZFS-port bug (blocks
  fast --use-openzfs host-bake images). NATIVE boot is unblocked (bare.raw
  recipe); native PG serves to "ready" then crashes on first fork (same disease).

## Tail-latency lever (open, inconclusive)
- batch-wake implemented + pushed (wip/tail-latency, wip/tail-latency-fork) but
  A/B was NULL/noise and has an smp>1 RX-wedge concern. The per-request
  wake->run->reply latency lever remains OPEN; MQ/RSS + wake-to-run scheduler
  path are the un-tried alternatives. (#1467 batch-wake, #1470 RSS, #1463 MQ,
  #1472 idle-pull, #1471 nitro-inbound, #1464/#1465 merged-adjacent are the
  net/sched PRs feeding this.)

## Net: what's genuinely blocked vs actionable
- BLOCKED (maintainer-gated, no self-serve action): #1455 gate and everything
  behind it (#1456/#1458/#1459/#1424), M2/PGXN.
- ACTIONABLE next focused session: #1423 pre-merge tidy (squash, drop
  DRAFT-BLOCKED banner, tests +=, tracking issue) -- but the substantive
  decisions are gated on a maintainer reply to the two open questions; and the
  fork-timer / wake-steer scale work (the running osv-steer agent owns this).

## Sweep 2026-08-17 sweep #2 (maintenance, alongside the tail-diagnostic scale agent osv-struct-*)
*** KEYSTONE LANDED: PR #1423 OpenZFS is MERGED. *** Upstream master ADVANCED
70446eb44 -> 0e34e4dc2 = my #1423 ("zfs: selectable in-kernel ZFS conf_zfs=
bsd|openzfs via upstream OpenZFS") SQUASH-MERGED by wkozaczuk 2026-08-17T16:19:21Z
(28th merged PR; #1473 ld-musl was 27th). Squash-merge: single commit 0e34e4dc2
authored+signed Greg Burd, PR head 70f23e8e3 content preserved (head not in
linear history = squash, expected). Local master ff'd cleanly to 0e34e4dc2
(ancestor-verified). The OpenZFS keystone feature is DONE on master.

HOW IT CLOSED: the brief expected #1423 still-open, ready-for-his-merge (his
14:54 "un-draft it" comment). Sequence: gburd 16:07 confirmed it was already
non-draft/mergeable-clean -> wkozaczuk merged it at 16:19. No further #1423 action
(it's merged). NO new reply needed; the ball is fully played.

#1424 CRUCIBLE BLOCKER-CHAIN NOW CLEARED: its three blockers (#1398 merged
2026-07-12, #1400 merged 2026-07-16, #1423 merged 2026-08-17) are ALL merged.
#1424 is still DRAFT/CONFLICTING/DIRTY and its title still says [BLOCKED on ...].
DID NOT rebase or un-draft it this round: maintainer offline til Nov, one
reviewable-PR-at-a-time, and rebasing a large driver PR speculatively is churn.
LEFT for a focused session: rebase #1424 onto 0e34e4dc2, drop the [BLOCKED]
title/banner, un-draft. Noted here as the now-actionable follow-up.

BASE-DRIFT from the merge: the #1423 merge touched shared files (Makefile,
core/pagecache.cc, include/osv/pagecache.hh, loader.cc, fs/vfs/main.cc,
drivers/virtio-blk.cc, .gitignore, .gitmodules, modules/tests/Makefile). The
CONFLICTING open PRs (#1424 #1438 #1440 #1441 #1445 #1447 #1449 #1456 #1458
#1459 #1475) conflict for legitimate base-drift reasons (most were already
CONFLICTING pre-merge). Did NOT mass-rebase (maintainer offline; churn without
review). The MERGEABLE/CLEAN ones stay clean: #1439 #1442 #1450 #1455 #1461
#1463 #1464 #1465 #1467 #1470 #1471 #1472. #1475 (fork-COW-lockfree scale fix)
remains DRAFT/CONFLICTING head 0b72ee0c6 (banks the scale win, intentionally on
its fork-stack base). NO reviewer comments on any gburd PR in the last 10 days
(the #1423 merge was a button-press, no comment).

Deps unchanged (OpenZFS 2.4.3 pin now ON MASTER via the merge; musl 1.2.6
backlog; lwext4/acpica forks fine). lwext4 #100 OPEN/0-reply/unchanged. Synced:
master ff'd to 0e34e4dc2; apps submodule working b2d53b3 (tracked gitlink
57c60798 NOT bumped, M apps working-state left; NEVER git-add-A). #1455 fork gate
STILL OPEN/unmerged -> #1456/#1458/#1459 stay blocked (#1424 now unblocked but
not yet rebased, above). Scale: MQ+PULL+fork-COW-lockfree shipped, tail-diagnostic
in flight (osv-struct). M2/PGXN pending behind the fork gate. Local tidy + EC2:
see ROADMAP sweep entry (pruned MY terminated osv-lat/osv-rebase/steer temps;
kept osv-struct's /tmp boot scripts + osv-steer-wt worktree; 0 EC2 of mine).

## Sweep 2026-08-15T13:02Z (maintenance, alongside a running WAKE-STEER agent)
NO-OP round. Verified intact: #1423 (restructure on PR head 6c4c39bb6, 29
commits, KVM-validated per 08:58Z comment; 2 open questions still unanswered),
#1473 (ld-musl, G-signed, base=master, mergeable, ready), #1463/#1470/#1472
(ready, mergeable), #1458 (parked-timer-unlink S-split comment present). No new
non-gburd comments on any PR since 2026-08-14 (wkozaczuk on #1423). #1455 fork
gate STILL open/unmerged. #1465 open/mergeable. Deps unchanged. lwext4 #100
still OPEN/0-reply. Synced: osv master == upstream af96db0f7 (no ff); apps
submodule == cloudius/master b2d53b3 (current). No draft drift (upstream
unchanged). Local tidy: 0 dead worktrees, 0 orphaned qemu/loop, .local 7.6G
(working worktrees + banks, kept); big /tmp consumers are OTHER agents'
(pgtv/solnix/segdbg) -- left; my small OSv /tmp scripts are today-fresh (steer
agent may use) or KB-scale -- left. No EC2 of mine (0 boxes). Did NOT touch the
osv-wakesteer worktree (running steer agent).

## Sweep 2026-08-17 (maintenance, alongside a running latency-diagnostic scale agent osv-lat-*)
Upstream master ADVANCED af96db0f7 -> 70446eb44 = my PR #1473 (ld-musl soname)
MERGED (27th merged PR). Local master ff'd to 70446eb44 (clean ff, ancestor
verified). ACTIONABLE #1 DONE = #1423 FINALIZED to merge-ready per wkozaczuk's
exact conditions (he is offline on OSv til ~Nov, so landed it promptly):
- rename tst-zfs-db-sim -> misc-zfs-db-sim: ALREADY on the branch (restructure
  agent did it); verified, no double-rename.
- gap-doc: added a concise KNOWN-FAILING-TESTS section to
  modules/open_zfs/FINDINGS-osv-openzfs.md (the 5 tests + brief why + "tracked,
  not regressions") + opened tracking issue #1474.
- SQUASH: 29 commits -> 1 (174548e79, G-signed). Off the PR's own base
  cb8c7205b. VERIFIED tree byte-identical (3ff0478a3) to the KVM-qualified head
  6c4c39bb6 + the 18-line docs gap-note ONLY -> build-equivalence to the
  qualified tree preserved (docs don't compile).
- FORCE-PUSH: done via the documented .envrc opt-in (PI_ALLOW_FORCE_PUSH=1) +
  force-with-lease branch-name+SHA form (--force-with-lease=pr/openzfs-draft:6c4c39bb6
  gh-fork HEAD:pr/openzfs-draft). Ref updated in place (6c4c39bb6...174548e79),
  NOT delete+recreate -> PR NOT auto-closed. Pre-push stale-base check (remote
  still 6c4c39bb6) + leak-scan (clean, ascii-only, no em-dashes) done first.
- UNDRAFT: PR was ALREADY isDraft=false (zfs-qual agent undrafted it); confirmed.
- Posted completion comment (issuecomment-5312436095). PR #1423 now:
  state=OPEN, isDraft=false, headRefOid=174548e79, commit count=1. MERGE-READY.
  Only GitHub-"conflicting" is a 1-line .gitignore adjacency (master added
  ext_images/, PR adds the patches !exception right after the same context line;
  both are keepers). Did NOT rebase (not asked; would risk the qualified tree)
  or touch tracked .gitignore. Noted in the comment, offered rebase if he wants.
Rest = NO-OP: other reviewer comments none-new (last non-self on #1455 nyh
2026-08-03, #1463 wkozaczuk 2026-08-01, #1439 nyh 2026-07-15 -- all old, already
answered). #1455 fork gate STILL OPEN/unmerged -> #1456/#1458/#1459/#1424 stay
blocked (no unblock). #1463/#1470/#1472/#1465/#1439 OPEN/non-draft/ready; #1458
DRAFT. Per maintainer (offline til Nov): HOLDING new PR submissions -- extra PRs
just queue. Deps unchanged (OpenZFS 2.4.3 latest+on-PR; musl 1.2.6 backlog;
lwext4/acpica forks fine). lwext4 #100 OPEN/0-reply/unchanged. Synced: master
ff'd to 70446eb44; apps submodule working b2d53b3 (tracked gitlink 57c60798 NOT
bumped, M apps working-state left). Scale: MQ+PULL shipped (climbs, RO c32 0.30x
/ RW 0.55x smp16), wake-steer MEASURED NULL/REGRESSION (shelved), per-request
latency = the re-opened lever (osv-lat agent in flight). M2/PGXN pending behind
the gate. Local tidy + EC2: see ROADMAP sweep entry.

## Sweep 2026-08-16T19:10Z (maintenance, alongside a running WAKE-STEER scale agent osv-steer2-*)
NO-OP round confirmed. Upstream master af96db0f7 UNCHANGED; local master ==
upstream (no ff). Newest non-gburd comment anywhere = wkozaczuk on #1423 at
2026-08-14T22:13:40Z (layout approval + 2 open decisions), ALREADY answered by
gburd 07:06/08:58Z with the KVM-qualification proof + a proposed test
disposition; no wkozaczuk reply since -> ball in maintainer's court, NOT
actionable. All 2026-08-15 comments are gburd's own. Recent work VERIFIED
INTACT: #1473 head f36481a19 (MERGEABLE, ready), #1423 head 6c4c39bb6 (29
commits, OPEN non-draft; mergeable=CONFLICTING is the base-drift note already
recorded, head intact), #1463 head 1454fd42f / #1470 head 0b78df3b4 / #1472
head f9fb81238 (all MERGEABLE, ready), #1465 MERGEABLE, #1458 parked-timer
S-split comment present (dad77b7fa, DRAFT). #1455 fork gate STILL OPEN/not
merged -> #1456/#1458/#1459/#1424 stay blocked. Deps unchanged (OpenZFS 2.4.3
== latest stable + on PR; musl 1.2.6 backlog; lwext4/acpica forks fine).
lwext4 #100 OPEN/0-reply/updatedAt 2026-07-14 (unchanged). Synced: osv master
already af96db0f7; apps submodule working state b2d53b3 == cloudius/master
(current, no ff; tracked gitlink 57c60798 = deliberate-commit decision, NOT
bumped). No draft drift (upstream unchanged). Local tidy: pruned 1233 stale
MINE /tmp scripts (33MB, Aug7-15 finished sessions), KEPT today-dated + steer
agent files (steer*/osv-steer2-*) + live-proc-referenced (trybuild.sh,
patch_execdyn.py = OTHER agents); 0 dead worktrees, 0 orphaned qemu/loop of
mine, .local 7.6G (working state, kept); big /tmp consumers (/tmp/bd 22G,
segdbg/asanrun, solnix-*.img, tmp.*) are OTHER agents' -- left. EC2: 0
instances of mine (3 solnix-buildfleet + 1 osv-steer2-host running = OTHER
agents, NOT touched); 1 available vol-0cd44b4c = solnix's (left); 0 orphans of
mine. Did NOT touch /tmp/osv-steer-wt (wip/pg-scale3) or the osv-steer2 agent.
