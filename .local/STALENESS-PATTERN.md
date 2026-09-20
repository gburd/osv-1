# Staleness pattern: base drift manufacturing phantom bugs

Two independent cases in a single session, both nearly cost real damage. This is
now the most important process finding of the program.

## Case 1: "lwext4 loses newly created files" (WRONG)

Symptom: PostgreSQL on ext4 appeared to lose files it had just created and
fsynced. We banked "ext4 is unusable for PostgreSQL / UNRUNNABLE on arm" as fact
and DRAFTED AN UPSTREAM BUG REPORT against lwext4.

Truth: a C reproducer written against the real lwext4 fork tip with OSv's exact
build config passes every case, including create + flush + crash + remount (the
guarantee fsync actually owes). lwext4 is fine.

Root cause: our branch lacked upstream `af27ba4b7` ("libext: real fsync +
page-cache bridge"). On that base
`#define ext_fsync ((vnop_fsync_t)vop_nullop)` - i.e. `fsync(2)` on ext4 was a
NO-OP, so PostgreSQL never flushed lwext4's write-back cache and lwext4 was never
asked to persist anything.

Cost avoided: filing a false bug against a dormant upstream project.

## Case 2: "OSv has a WAL-fsync tail-latency bug" (ALREADY FIXED UPSTREAM)

Symptom: at VU32, a 19.3 s stall. `pg_stat_activity` showed 1 backend in
`IO|WalSync` with 21 backends convoyed behind `LWLock|WALWrite`, while PG's own
checkpoint accounting for the same window was `write=153.384s` but
`sync=0.033s` - proving PG's fsync path was fast and the stall was BELOW PG, in
the guest block path.

Truth: upstream `ae077860c` ("virtio-blk: do not hold the per-queue lock while
draining completions") already fixes exactly this. Its commit message names the
scenario: "Under heavy sustained write load (e.g. a ZFS checkpoint storm) with a
full ring this wedges: the producer sleeps in add_buf_wait holding the queue
lock, req_done spins on that lock, and I/O progress stops with no recovery."

Verified ancestry: `1e3d84143` (virtio-blk multiqueue, which INTRODUCED the
deadlock) IS an ancestor of our v26; `ae077860c` (the cure) is NOT. So v26 has
the bug-introducing feature without the fix.

Cost avoided: writing an OSv patch for a bug upstream already solved, and
publishing p99 conclusions confounded by a stall unrelated to the knobs.

## Case 3 (related): a generic fix buried in a feature commit, never upstreamed

While upstreaming the aarch64 FEAT_RNG fix (#1493) it would not cherry-pick,
because it depends on an x86 RDRAND-in-`random_read` fix that was NOT on master
and NOT in any PR: it was buried inside fork mega-commit `858dd78f2` ("fork:
cross-AS coherence for epoll containers, rcu_defer wait_records, per-backend pid
+ SIGURG latch routing..."). The hunk is fully self-contained; its own comment
says "independent of fork". Extracted as #1492.

So staleness cuts both ways: we lack upstream fixes, AND upstream lacks ours
because generic fixes get swept into large feature commits.

## Standing rules this produced

1. Before concluding "X is broken", verify the base contains the relevant
   upstream fix. `git merge-base --is-ancestor <upstream-fix> <our-branch>`.
2. When a symptom looks like a known class of bug (fsync not durable, I/O
   wedging under load), grep upstream's log for a commit whose message names that
   scenario before writing any code.
3. To test whether a PR conflicts, dry-run `git merge-tree` from a worktree
   CHECKED OUT AT upstream/master so `.gitattributes` merge drivers are active.
   Trust merge-tree over GitHub's cached mergeable flag.
4. Audit large feature commits for self-contained generic fixes that should be
   extracted and upstreamed on their own. Each buried fix is value already paid
   for but not delivered.
5. Any benchmark result must record the base it was measured on, and results from
   different bases are not comparable.

## Immediate consequences

- P0.4 (rebase the fix stack onto current upstream/master) is a HARD GATE before
  P1/P3/P4/P5. Two phantom bugs in one session is enough evidence.
- The p99 answer is currently unobtainable on v26: the dominant tail term is the
  `ae077860c` stall, not any PG knob. Re-measure after the rebase.
- The ext4 arm conclusions must be re-run on a base with `af27ba4b7`.
- Audit the remaining fork mega-commits for extractable generic fixes.
