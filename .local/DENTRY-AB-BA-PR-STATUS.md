# The AB-BA fix: written, 4 commits, MASTER-ELIGIBLE. PR not yet opened.

2026-09-09. Agent 1b02c3e6 is actively working it (224 tool uses, healthy rate). Branch
**`gh-fork/wip/dentry-lock-order`** pushed; **no PR yet** - it is still validating before filing,
which is correct.

## The four commits, all G-signed, structured exactly as briefed

    6e250b6da  vfs: fix AB-BA deadlock between dentry_hash_lock and the vnode lock
    48d2ea04c  vfs: do not allocate while holding dentry_hash_lock in dentry_move()
    a642706e2  vfs: split the global dentry hash lock into per-chain locks
    646745511  tests: concurrency stress for the dentry cache lock order

Separate commits per defect, as asked, so each can be measured and reviewed independently.

## MASTER-ELIGIBLE, verified three ways
    based on upstream/master (0e34e4dc2)?   YES
    CONF_fork references in the 4 commits?  0
    merge-tree against upstream/master?      RC=0, zero conflicts

**This is the first non-fork-gated fix of the entire campaign.** Everything else has been confined to
#1456 comments because master has no `fork()`. An AB-BA inversion is a defect with or without fork;
fork merely supplied enough concurrent `open()`/`drele()` traffic to hit it.

## The ordering rule is documented IN CODE, not just in a commit message

    LOCK ORDERING RULE (whole VFS):
        vnode lock (vn_lock)  ->  dentry_hash_lock
    and NEVER the reverse.  namei() establishes this direction: it holds vn_lock(dvp)
    across dentry_lookup()/dentry_alloc(), both of which take dentry_hash_lock inside.

with the observed failure recorded alongside it ("all vCPUs halted in do_idle with an empty wakeup
mask and >1000 threads parked, while memory was plentiful").

## Both hazards I flagged are handled

**The refcount race** - my specific worry about dropping the lock mid-`drele`. Resolved by unlinking
*under* the lock and only then releasing:

    LIST_REMOVE(dp, d_link);        // still holding the lock: nothing can find dp now
    dentry_hash_lock_release();
    vn_del_name(dp->d_vnode, dp);   // vnode touched only after release

with the reasoning in the comment: once off the chain `dentry_lookup()` cannot resurrect it, so this
thread is sole owner and `d_refcnt` is 0 and stays 0. That is the correct resolution, not a hopeful one.

**The assertion with teeth** - `vn_lock()` now asserts the order rather than documenting it:

    #ifdef DEBUG_VFS
        ASSERT(!vfs_dentry_hash_lock_held());
    #endif

so a future reintroduction of the inversion fails loudly instead of hanging a machine.

## Still outstanding before the PR
- Correctness evidence (the `tst-*` suite plus the new concurrency stress), and the assertion
  demonstrated **firing on the unfixed code** and silent on the fixed - the "prove the check has teeth"
  standard the campaign has held to throughout.
- Whether it **reproduces without fork**, which decides whether the PR can claim master relevance on
  its own merits rather than as a fork-adjacent finding.
- The per-chain split must be shown to **preserve the new ordering** (a per-bucket lock still inverts
  against `vn_lock`), which is why the ordering fix is commit 1 and the split is commit 3.
- Then the measurement: baseline vs fork-only vs fork+dentry, x86 first, aarch64 if capacity allows.

## Task 1 PROVEN, and the evidence is stronger than a reproduced hang

### The assertion fires on a BOOT PATH, single-threaded
On unfixed code, `ASSERT(!vfs_dentry_hash_lock_held())` in `vn_lock()` fires during `vfs_init` with:

    vn_lock+168 <- vn_del_name+17 <- drele+103 <- vfs_file::close()+87 <- fdrop+80 <- close+23

I verified `fdrop` is on the ordinary `close()` path (`fs/vfs/main.cc:154/159/194`). **So the illegal
order is taken by every `close()` that drops a last dentry reference** - routine, boot-path,
single-threaded code, not a rare interleaving. On fixed code the assert is silent and the test prints
OK, same test and config, only the vfs source differing.

**That is a better claim than "we reproduced a hang under load."** The lock cycle is constructed
constantly; the only missing ingredient is a concurrent `namei()` on the same vnode, which the gdb
trace from the wedged guest independently supplies (184 backends, owner held, `vn_lock` on the other
side). **Proven-defect + observed-hang is a complete argument.**

### The agent's honest negative, which I am keeping in the PR
Its concurrency harness (`tst-dentry-lock`, 48 threads x 400 iters, **172,800 ops**, 16 vCPU TCG)
**PASSES on unfixed code.** It does not wedge. Cause: the inversion needs a second thread holding
`vn_lock` on the *same* vnode and waiting for the chain lock at that instant, and OSv's mutex hold is
short - under TCG with no KVM the window is tiny. The observed deadlock needed **184 concurrent PG
backends on 32 real vCPUs**.

This must go in the PR body: a reviewer who runs the test on a laptop and sees it pass must not
conclude the bug is fictional. Pre-empting that is worth more than hiding it.

## Direction given
- **File against `cloudius-systems/osv:master` NOW**, before the measurement - the fix is done and
  should not sit unfiled while hours are spent on metal.
- **Lead with the ordering rule**, not the deadlock story: "the VFS has an implicit order
  `vn_lock -> dentry_hash_lock` established by `namei()`; `drele()` violated it; here is an assertion
  that enforces it." The hang is the motivation, not the thesis.
- Offered the option to **split the per-chain change into its own PR** if that keeps the correctness
  fix minimal and mergeable - a reviewer may want the deadlock fix without the lock-structure change.
- **Do not overstate the throughput implication.** The per-chain split is unmeasured; say so.

## Measurement priority CHANGED by this finding
The deadlock fix is a **hang** fix, so its throughput contribution is zero until you hit it. The
**lock contention** is what could move NOPM. So the arms become **baseline vs fork-only vs
fork+per-chain**, and if the clock forces a cut, the deadlock-only arm is what gets dropped.

## Box discipline
One `c5.4xlarge` (`i-07d9a3e6c9c1e1192`), **no metal launched yet** at 3.5h elapsed - exactly the
sequencing asked for. Metal only once there is a validated image, with the same osv SHA across dev and
measurement.

## PRs FILED: #1502 and #1503, both against cloudius-systems/osv:master, both MERGEABLE

    #1502  vfs: fix AB-BA deadlock between dentry_hash_lock and the vnode lock
           (3 commits: ordering fix + assertion, dentry_move strdup, the test)
    #1503  vfs: split the global dentry hash lock into per-bucket locks  (stacked on #1502)

Verified by me: both `base=master`, both `MERGEABLE`. **The first non-fork-gated upstream work of the
entire campaign** - everything else has been confined to #1456 comments because master has no `fork()`.

Split exactly as offered, so a reviewer can take correctness without the lock-structure change.
#1502 leads with the ordering rule, carries the verbatim before/after assertion pair, and **states
plainly that the stress test passes on unfixed code and why** (172,800 ops, 48 threads, TCG, short
mutex holds), crediting the production gdb trace for the hang. #1503 **explicitly says the throughput
effect is unmeasured** and makes no claim. Zero em-dashes, leak-scanned, all `%G?`=G.

## Metal substrate proven, PG serving, and every known trap avoided
- image **63 MB** with "cpiod finished" and 7 manifest entries (versus the 10 MB PG-free trap)
- OpenZFS proven **build-time**: 311 zfs objects incl `openzfs_osv_compat.o`, **zero** bsd `fs/zfs`
  spa objects, all four OpenZFS-only libs
- pool created **once**, `ashift=12`, 400G raw file on instance-store NVMe (838G XFS,
  non-rotational); all six properties verified **from inside the guest**
- boots in ~290-376 ms under KVM
- `VFSFLAG OSV_VFS_DENTRY_PERBUCKET unset, default 1` prints every boot - proof-of-binding as asked
- PostgreSQL 18.6 musl listening on 0.0.0.0:5432, "ready to accept connections", GUCs via `-c`

## The seed_copy blocker: diagnosed as an ORDERING problem, not a seed_copy bug
Two facts from source:

    module.py:13   '--mount-fs=ramfs,/dev/null,/data '
    module.py:14   '/usr/bin/seed_copy /data-seed /data ; '
    build.sh:229   '/data: ${MODULE_DIR}/emptydir'
                   "# empty mount point for the writable ramfs /data (rofs cannot mkdir at runtime)"

`/data` in the image is a **baked empty directory that exists only as a mount point**, and the stock
cmdline mounts over it **before** `seed_copy` runs. **If `seed_copy` runs before `/zfs.so mount pgdata`
puts the dataset at `/data`, it writes into the read-only ROFS mount point** - dataset stays 96K, no
loud error. Exactly the reported symptom.

Required chain: `zpool import -N` -> `zfs mount pgdata` -> `seed_copy` -> `postgres`, **with
`--mount-fs=ramfs,/dev/null,/data` dropped** (else the seed lands in RAM - the trap that caught this
campaign before). Verify `/data` is `zfs` not `ramfs` **at the moment seed_copy runs**, not just at the
end.

Two alternative causes given if the order is already right:
1. **`seed_copy` is NOT silent on error** - it `perror()`s on every failure path (`seed_copy.c:24-53`).
   So "silent, copies nothing" is inconsistent with an attempted-and-failed copy and points at the
   **source** being empty. `build.sh:201-208` documents that **OSv manifest `**` globs capture only
   files, so empty directories are dropped**, worked around by touching `.keep` in each. If that step
   did not run, the seed is partially or wholly absent.
2. Confirm `/data-seed` has content in the guest at all.

## Time discipline imposed
At ~5.5h with metal running: **30-45 minutes on the seed problem, then stop and report.** The
measurement is the **least important** of the three deliverables - it is cheaply re-runnable now the
substrate recipe is proven, whereas the two PRs and the ordering proof are done and irreplaceable.

Also flagged: with `OSV_VFS_DENTRY_PERBUCKET` defaulting to **1**, the baseline arm requires setting it
to **0** - check the flag's polarity before attributing anything.
