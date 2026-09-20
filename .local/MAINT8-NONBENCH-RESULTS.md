# Non-benchmark issue sweep (agent 97dc21c0) + my follow-through

2026-09-07. Four tasks, three premise corrections, one of my own PRs fixed.

## The fork TLB hazard: filed on #1475, not #1456

My brief was wrong in three ways and the agent re-aimed the finding rather than writing
up my version. Corrected facts (paste-ready, verified):

    Unsound line:  #1475 pr/fork-cow-nested-lockfree @ 0b72ee0c6
                   core/mmu.cc:2029-2033 (flush_tlb_local when exception_depth>=2)
                   justification at core/mmu.cc:2022-2026 is false for AS0
    Root cause:    core/mmu.cc:320-325  parent's PTEs marked COW too, so the parent
                   faults in AS0, which IS live on many CPUs
    NOT on #1456:  wip/fork-stage2-pr @ e9a31b1ab has unconditional flush_tlb_all at
                   core/mmu.cc:2097; 0 occurrences of flush_tlb_local
    AS inherit:    core/sched.cc:1094  (NOT 1382)
    No CR3 reload: arch/x64/arch-switch.hh:114 (switch_as), :148 (cr3 write, in-branch
                   only); arch/x64/mmu.cc:94 (lazy_flush_tlb armed only by
                   flush_tlb_all); core/sched.cc:403 (consumer)
    signal.cc as_for_pid cross-AS injection: libc/signal.cc:559 + :718, ONLY on
                   integ/pg-fork-zfs (#1458) and wip/fork-clone-scan. NOT on
                   #1455/#1456/#1475.

Posted: PR #1475 issuecomment-5574522695. The agent closed all three self-healing escape
hatches (same-AS switch never writes CR3; lazy-flush is armed only inside
flush_tlb_all so the local branch never arms it; no other write_cr3 callers), and
labelled it honestly "hazard demonstrated by construction, not yet demonstrated at
runtime" with no reproducer built.

## #1497 was MY OWN PR and its published verification table was WRONG

The agent disagreed with a PR another agent had just opened. It was right. I re-verified
by executing the resolver, not reading it:

    module list "zfs" WITH the patch  -> modules=['bsd_zfs', 'zfs']
        from bsd_zfs -> 1
        from zfs     -> 1
        TOTAL libsolaris.so lines: 2

The PR claimed "still yields exactly one line" and reasoned that "a provider and the
placeholder resolve to the same module object". Both false: the placeholder `require()`s
the provider, so both appear as distinct resolved modules and `generate_manifests`
appends each.

Fix verified in all four configurations (keep the entry on providers, DELETE it from the
placeholder):

    zfs                     1
    open_zfs                1
    zfs,zfs-tools           1
    open_zfs,zfs,zfs-tools  1

Actions taken: corrected branch `pr/zfs-provider-manifest-v2` (commit 3f0c4579f, G-signed,
leak-scan clean), a correction comment posted (issuecomment-5574648849), and the wrong
sentence removed from the PR body. Note my first `gh pr edit` regex silently missed the
sentence because I guessed its wording; I re-read the body, anchored on the exact text,
and asserted the anchor existed before replacing. Residual wrong claims: 0.

**This is the value of cross-checking our own output.** A published table that does not
hold is worse than no table, and it was on track to reach the maintainer.

## #1496 verified: AGREE, and the PR undersells itself

Reproduced on pristine master by running `make -n fs=ramfs ... loader.img`:
`grep -c "tools/mount"` = **0**, i.e. the tools are never built at all; nothing else in
the tree builds them. `mkbootfs.py:63` then dies with
`FileNotFoundError: 'tools/mount/mount-fs.so'`. With the patch both tools link at
dry-run lines 2385/2389, BEFORE MKBOOTFS at 2390.

Correction to that PR's wording: it calls the failure "timing dependent" and a "race".
It is neither. On stock master `fs=ramfs` has **no rule at all** ordering these, so a
clean tree fails **deterministically**; only a pre-populated tree accidentally passes.
Scope checked and correct: rofs's skel does not name the tools, ext uses a different
skel, zfs is already covered.

## ext4 / #1447: premise holds, verdict = keep draft

`af27ba4b7` IS an ancestor of upstream/master and of `pr/ext4-perf-v2`, but **not** of
`pr/ext4-perf` (the actual PR head). `ext_fsync` is real at
`modules/libext/ext_vnops.cc:627-641`, wired at `:1549`.

The insulation argument is not only accurate, it is provable more strongly than the PR
states: libext never puts file data in the lwext4 block cache in EITHER direction (reads
via `ext4_blocks_get_direct`/`ext4_block_readbytes` -> `ext4_bdif_bread`; writes via the
_direct/_writebytes pair). `grep ext4_block_get|ext4_bcache` across modules/libext
returns nothing; the cache holds only metadata.

**Important expectation-setter for the re-measurement:** file data was ALREADY written
synchronously via `bio_wait` (`ext_vfsops.cc:46-81`), so the old no-op fsync was skipping
the **metadata** flush, not the data. The retraction still stands (data on disk with a
stale inode is not durable), but a re-measured `seq_write_fsync` **may move much less
than "the old number measured nothing" implies**. Do not expect a collapse.

Separate finding, not filed: neither `ext_fsync` nor the block layer ever issues
`BIO_FLUSH`, though drivers support it (`drivers/nvme.cc:443`,
`drivers/virtio-blk.cc:423`). So ext `fsync()` is "handed to the device", not power-loss
durable.

## Hygiene sweep across 45 open PRs

Acted on within the two standing exceptions: **39 em/en-dashes removed across 8 PRs**
(#1442,#1445,#1449,#1450,#1455,#1456,#1458,#1459), `->` normalised, 0 dashes remain in
any open PR body. Two factual fixes: #1470 ("Draft pending" but the PR is not draft) and
#1463 (did not mention that its MSI-X commit is now separately reviewable as #1465).

The agent also **caught its own error mid-task**: its first conflict scan ran from a
worktree lacking `.gitattributes`, so the `modules/tests/Makefile merge=union` driver was
inactive and produced FALSE conflicts. That is the identical mistake that caused #1489 to
be opened and retracted. It re-ran from a correct worktree.

Real conflicts found: #1438/#1441/#1445 share an add/add on `core/numa.cc`+`numa.hh`
because master merged NUMA discovery (a92c44f9b) independently; **#1438's actual
contribution over master is 10 lines** (`node_of_phys`), so rebasing turns a 198-file
conflicting diff into a tiny one. #1456/#1475 have a real `libc/signal.cc` conflict
against merged #1457 (6c9d0489b). #1440 and #1449 are CLEAN despite GitHub saying
CONFLICTING, confirming again that GitHub's cached flag does not apply the union driver.

#1476 flagged: perf-motivated but qualitative, no numbers. Either measure it or state it
is unmeasured.

## Decisions I made
- Fixed #1497 myself (done, above) rather than leaving another agent's defect published.
- Rebases of #1438/#1441/#1456 NOT done yet: deliberate, since #1456 is mid-campaign and
  #1438's rebase should be verified against master's NUMA merge with care.
