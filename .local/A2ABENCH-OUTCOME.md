# Benchmark attempt 6: killed by the account, not the code. What survived, and the one real result.

2026-09-11, agent 2e50611c. `bene` expired at 12:03:00 UTC mid-run, taking four boxes and the sweep.

## THE POSITIVE RESULT: the TCB fix holds under real production load

This is the answer to a question that blocked five previous attempts. Verified on base `cbbf74e7`:

    stack_guard = 3   OSV_FORK_RANGE_BS = 2   OSV_FORK_LARGE_SHARE = 2
    apps 5cb19033 | image 114 MiB (not the 8 MB PG-free signature)
    302 open_zfs objects / 0 bsd-zfs | ashift=12 via `zpool get` | no tmpfs
    all 12 mandated GUCs verified EXTERNALLY as source=command line | PG 18.6 serving
    200-warehouse / 19 GB TPROC-C schema BUILT with NO __stack_chk_fail abort
      through many hundreds of forks

The defect previously aborted after **1-5 cumulative forks**. Building a 19 GB schema is a far stronger
demonstration than any microbenchmark, and it means **PR #1504 is validated under load**, not just by a
unit test.

**Zero NOPM cells completed**, so the SHAPE-vs-LEVEL question is still unanswered. The agent explicitly
refused to estimate it, which is right.

## Two defects found that are worth more than the missed cell

**(a) The "EACCES at depth 2" is NOT a ZFS bug - my brief was wrong.** `scripts/gen-rofs-img.py:53-55`:

    DIR_MODE = 0x4000   REG_MODE = 0x8000   LINK_MODE = 0xA000

assigned unconditionally at `:206/212/219/244`, so **only S_IFMT type bits are stored and the permission
field is discarded entirely.** `rofs_getattr` (`rofs_vnops.cc:261`) then *invents* `0555`. `seed_copy`
faithfully preserved that invented mode, creating a destination tree with no owner-write bit, and the
next level's `O_CREAT` hit `vn_access(VWRITE)` -> EACCES.

I told the agent to "diagnose rather than work around" and to treat it as ZFS. **It proved my framing
wrong and found the real layer.** Its own correction to me was also finer than mine: the generator
stores *zero* permission bits, and the `0555` a caller sees is invented downstream by `rofs_getattr` -
two distinct layers, only one of which is the root cause.

**FIXED AND LANDED**: `apps` commit `3f93f43` (G-signed), pushed to `gh-fork/wip/postgres18-musl-demo`,
PR **osv-apps#73** head now `3f93f43f4`, disclosed at issuecomment-5635370939. Compiles clean. The fix
existed only as prose in a report and on a dead box; it is now in a PR.

**(b) `fs=rofs` image builds fail while `scripts/build` exits 0.** `Makefile:2242-2244` gates `$(tools)`
and `libsolaris.so` on `ifeq ($(fs),zfs)`, so an `fs=rofs` build never produces
`libsolaris.so`/`zpool.so`/`zfs.so`. **Fifth instance of the silent-success class** (after the shadowed
`build` target, the no-op `ext_fsync`, the ramfs PGDATA, and bsd_zfs masquerading as OpenZFS).

The agent also **narrowed rather than contradicted** my `--use-openzfs` warning: on the `fs=zfs` path it
still holds that only `--use-openzfs` avoids the cpiod push; the flag is merely **inert** once `fs=rofs`
is chosen. It noted that in the file so a future reader does not discard a warning that remains true.
That distinction is the difference between correcting me and over-correcting me.

## What survived, and why
**Everything, because it wrote to the workstation as it went.** `.local/a2abench/` holds the full result
document plus nine scripts - `build-image.sh`, `boot.sh`, `seedprep.sh`, `hdb.sh`, `cell.sh`, `probe.py`,
`instr.sh`, `host-setup.sh`, `drv-setup.sh`, `env.sh` - i.e. **the entire substrate recipe and the 7-step
sequence that worked.** The next attempt starts from a proven harness.

**Four previous agents lost work to context exhaustion on a box. This one lost an account and lost
nothing**, which is the push-early discipline earning its keep.

## The four boxes
Unreachable and unterminable: `i-0126a936629a68911` (m5d.metal), `i-09744de8dee537964` (c7gd.metal),
`i-01a9667ad35f58299`, `i-09dfc1589c8eb9c2c`. They die with the account; billing stops with it too.
**There is no orphan because there is no longer an account to hold one.**

## My error, recorded
I never asked `bene`'s expiry and launched a multi-hour benchmark into an account with 40 minutes left.
**Standing rule: a burner's expiry goes into the plan at first use, and any run over an hour is checked
against remaining time before launch.**
