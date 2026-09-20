# #1502 review BODY (nyh, CHANGES_REQUESTED 15:02Z) - ALL THREE CHARGES VERIFIED TRUE. He is right.
# He does NOT dispute the fix ("The bug is real and the fix is correct"). He attacks my CLAIMS. Two are in
# committed history, so fixing them requires rewriting commit messages, not just a reply.

## CHARGE 1: the reachability argument in commit 48fc66000's message is WRONG. VERIFIED.
My message says: "It is reachable whenever the dentry being released is a directory, which namei() itself
does on every path component, so it is not theoretical."
HE IS RIGHT THAT THIS DOES NOT HOLD: namei() holds a dref on ddp while holding vn_lock, so a concurrent
drele() on that dentry cannot reach refcount 0; and two threads walking the same path get the SAME dentry.
The race actually needs TWO DISTINCT DENTRIES ALIASING ONE VNODE - which my message never says.
HIS STRONGER REPLACEMENT (accept it): sys_rename() holds vn_lock(vp1) - ANY vnode type, not just a
directory - across lookup(dest) and dentry_move()/dentry_remove() (vfs_syscalls.cc:730/746/827-829), so the
A-side is NOT directory-restricted. Recipe: thread A renames /a -> /c while thread B does the last close()
of /b, where /a and /b are hardlinks to ONE file. Needs ZFS: ramfs_link is vop_eperm (ramfs_vnops.cc:746),
so ramfs cannot even create the hardlink the recipe requires - which ALSO explains why my ramfs-based
stress test could never reproduce it (see charge 2).

## CHARGE 2: the "test wedges unfixed code" claim CONTRADICTS my own PR body. VERIFIED - a flat conflict.
tests/tst-dentry-lock.cc header (committed in ccfedefd4) says:
  "On unfixed code this hangs (the harness kills it by timeout)."
The PR BODY says, in bold: "The included stress test passes on unfixed code." 48 threads x 400 iterations,
172,800 operations, 16 vCPUs under TCG, no wedge.
=> The PR body is the HONEST one; the test header is an aspirational claim the measurement refuted and I
never went back and corrected. He is right to press it, and his inference is reasonable: if the test does
not reproduce, maybe the scenario is wrong. The ANSWER is now clear from charge 1: the test uses ramfs, and
ramfs_link is vop_eperm, so the test CANNOT construct the two-hardlinks-to-one-file aliasing the race
requires. The test is not wrong about concurrency; it is testing on a filesystem that cannot express the
precondition. Also owed: how long the test runs.

## CHARGE 3: "dentry_hash_lock is now a leaf lock" is OVERSTATED. VERIFIED FALSE AS WRITTEN.
My message says: "dentry_hash_lock is now a leaf lock: it calls out to no other subsystem."
But vfs_dentry.cc:207-209 calls dentry_children_remove(dp) INSIDE WITH_LOCK(dentry_hash_lock), and
dentry_children_remove takes dp->d_lock at :172. So the hash lock DOES nest another lock.
He checked all 4 sites and found NO inversion - so the FIX is sound and the ORDER is consistent; only my
"leaf lock / calls out to no other subsystem" phrasing is wrong. Correct claim: dentry_hash_lock no longer
calls into the VNODE layer (which is what the AB-BA fix achieved); it still nests d_lock, consistently.

## HIS DIRECT QUESTION: "you said you saw this bug in practice, what use case did it use?"
THE HONEST ANSWER, from my own notes (.local/WEDGE-BACKTRACE-CAPTURED.md), is worse than he suspects:
THE OBSERVED REAL-WORLD WEDGE WAS NOT THE AB-BA INVERSION. It was commit 2's blocking allocation:
  mutex: {count = 8, depth = 1, owner = 0x40032f208040, sequence = 92}
  owner = LIVE thread 220584 (postgres), stack: ... #3 memory::page_pool::l1::alloc_page core/mempool.cc:1464
i.e. the dentry_hash_lock OWNER was blocked inside the page allocator while holding the global VFS lock -
which is exactly what commit 2581e0c36 (do not allocate while holding dentry_hash_lock in dentry_move)
fixes. My notes even record: "My 'lost wakeup, the lock is the victim not the cause' reading was WRONG...
the owner is blocked inside the page allocator while holding the global VFS lock."
=> So commit 1's "Observed on a 32-vCPU guest... every vCPU halted in do_idle" paragraph attributes a real
observation to the WRONG FIX. The AB-BA inversion is a real latent bug found by CODE READING; the thing we
actually observed in production was the allocation-under-lock stall. The workload was stock PostgreSQL
(184 concurrent backends) doing open()/close() traffic on /pg/postmaster.pid and friends under HammerDB.

## WHAT I OWE (and it requires REWRITING COMMITTED MESSAGES, not just a comment):
1. commit 48fc66000 message: DELETE the wrong reachability sentence; replace with his sys_rename()/hardlink
   aliasing argument. REMOVE or correct the "Observed on a 32-vCPU guest" paragraph so the observation is
   attributed to commit 2 (allocation-under-lock), not to the AB-BA fix. Fix the "leaf lock" sentence to
   "no longer calls into the vnode layer; it still nests d_lock, consistently".
2. tests/tst-dentry-lock.cc header (ccfedefd4): DELETE "On unfixed code this hangs"; state honestly that it
   does NOT reproduce on ramfs and WHY (ramfs_link is vop_eperm, so the hardlink aliasing the race needs
   cannot be constructed), and what it DOES cover (concurrency stress + the DEBUG_VFS order assert).
3. Answer his question directly and correct the record: the production observation was the allocation
   stall; the AB-BA was found by reading the code. Say so plainly rather than defending the original wording.
4. Report the test's runtime.

## ALL ADDRESSED 2026-09-20. Series rewritten + force-with-lease pushed: c7ab5929e (4 commits, all G-signed).
## ONLY code change vs the reviewed head = the test header comment; everything else was commit messages.
 1. commit 03e94520a (was 48fc66000): wrong reachability sentence DELETED, replaced with nyh's
    sys_rename()/two-hardlinks-aliasing-one-vnode argument (vfs_syscalls.cc:730/:746/:827-829, vp1 is any
    vnode type so the A side is not directory-restricted). "leaf lock: calls out to no other subsystem"
    corrected to "no longer calls into the vnode layer; still nests d_lock, consistently, no inversion".
    The production-observation paragraph MOVED OUT and replaced with an explicit statement that the
    inversion was found by CODE READING, and that the observed hang belongs to the next commit.
 2. commit 2ef64acd3 (was ccfedefd4): the test header's "On unfixed code this hangs (harness kills it by
    timeout)" DELETED. Now states it does NOT and CANNOT reproduce on ramfs (ramfs_link is vop_eperm so the
    hardlink aliasing cannot be built), what it DOES cover (dentry-cache paths under contention + the
    DEBUG_VFS order assert as the cheap catch for a reintroduced inversion), that it passes before AND after,
    and the runtime (48 threads x 400 iters, ~172,800 ops, well under a minute on 16 vCPUs under TCG).
 3. HIS DIRECT QUESTION answered honestly and it was worse than he guessed: the observed wedge was the
    ALLOCATION-UNDER-LOCK defect (owner blocked in memory::page_pool::l1::alloc_page at mempool.cc:1464
    while holding dentry_hash_lock - commit 2's fix), NOT the AB-BA inversion. Stated plainly rather than
    defending the original wording. Workload: stock PostgreSQL, 184 concurrent backends, HammerDB, 32 vCPU.
 4. PR BODY updated with an "Update after review" section recording all three corrections, so the
    contradiction he found is resolved in the description too, not just in a comment.
 Reply: #1502 comment 5750804145.

## THE REAL LESSON (bank it): I let a commit message assert a reachability argument I had not verified, and
## attach real evidence to the wrong fix, and I left an aspirational test-header claim standing after my own
## measurement refuted it (the PR body said "passes on unfixed code" while the header said "hangs"). The fix
## was right; the CLAIMS around it were not. A reviewer reading only the messages would have been misled.
## Rule going forward: a commit message may only claim what was measured or verified, evidence attaches to
## the commit it actually supports, and when a measurement refutes a comment, the comment gets corrected in
## the same change - not left for a reviewer to catch.
