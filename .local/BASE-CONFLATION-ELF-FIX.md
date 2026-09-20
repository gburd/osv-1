# False alarm, real briefing error: I conflated "repinned" with "repinned + the elf fix"

2026-09-09. Agent 7d0737f3 captured the elf/dlopen page fault on a base it believed contained the
fix, and correctly raised it loudly as a possible regression. **The fix was never in that base.**

## Verified

    da3041f5d / 6265b5ce5 / db84c2da1 / 761987065
      ancestor of wip/pg-v26-faultfix-repinned?   NO, all four

    grep -c remap_segments_in_current_address_space core/elf.cc
      fix/elf-object-cache-address-space   3
      wip/aarch64-boot-plus-elf-as-fix     3
      wip/forkroot-arm-base                3
      wip/pg-v26-faultfix-repinned         0   <- the base under test
      wip/pg-v26-faultfix                  0

So the captured fault is the **expected pre-fix behaviour**, faithfully reproduced, and says nothing
about the fix's completeness.

## My error
I described `wip/pg-v26-faultfix-repinned` as "the x86 base, apps pin fixed" and separately said the
elf fix was "runtime-validated on both ISAs". Both statements are true and they refer to **different
trees**: `repinned` is `wip/pg-v26-faultfix` plus only an `apps` submodule re-pin, while the x86
validation was done on a tree the other agent assembled itself. I should have written "repinned **+
the elf fix**". **Second time today I conflated two branches in a brief** (the first was telling the
aarch64 agent the elf-fix branch contained the aarch64 boot fixes).

**Cheap guard, now standing: before booting, verify the fix is present with a one-line grep for its
central symbol.** `grep -c remap_segments_in_current_address_space core/elf.cc` returning 3 would have
saved this run in one second. Ancestry checks (`git merge-base --is-ancestor`) are the other half.

## The agent's behaviour was right
It raised a suspected regression **loudly and immediately** rather than working around it. Had the
ancestry held, this would have been a serious regression on a fix already reported as validated on
#1456. A silent workaround would have left me believing the fix was validated on a tree it had never
been in.

## The finding that actually matters from that run: a checkpoint storm
Captured alongside the fault:
- a **269.744 s checkpoint write**, against 3-25 s for its neighbours;
- repeated `checkpoints are occurring too frequently (4 seconds apart)`, distance ~540 MB each.

**Suspicion, and it is the agent's, not mine: the GUEST may not have `max_wal_size=64GB`.** I set that
in the brief for both sides, but the OSv guest's cluster comes from a **host-side `initdb` baked into
a seed image**, so the seed's `postgresql.conf` can carry a small `max_wal_size` regardless of what
the Linux arm received. Instructed to read it **externally** with `SHOW max_wal_size` from the driver
rather than trusting the file.

**If the guest has been running at the 1GB default while Linux ran at 64GB, then every OSv number in
this campaign was measured under a checkpoint storm Linux was never subjected to** - a confound in
**OSv's disfavour** that would partially explain the 22x throughput gap. That is more important than
the Firecracker arm, and it is now the priority.

Either answer is valuable: if the guest is already at 64GB, the checkpoint storm is a genuine OSv
finding rather than a configuration artifact.

## The checkpoint-storm finding was RETRACTED by the agent, and correctly so

Within one message of proposing it, agent 7d0737f3 withdrew its own finding. The cause was its own
missing GUCs, not an OSv pathology:

- The OSv seed cluster's baked `postgresql.conf` carries **stock defaults**
  (`shared_buffers = 128MB`, `max_connections = 100`, `max_wal_size` unset = 1GB).
- The prior x86 arm passed the campaign GUCs on the **`postgres` command line** and verified them
  externally. Its report shows `max_wal_size 65536 MB (= 64 GB, not 16)` and
  `shared_buffers 2097152 8kB (= 16 GB)`, with a section headed "Checkpoints at
  `max_wal_size=64GB`: your premise confirmed". **I verified that.**
- This run's guest cmdline was `/usr/bin/postgres -D /data/pg` with **no `-c` args at all**, so it ran
  on 128MB shared_buffers / 1GB max_wal_size. That produced the 540 MB checkpoint distance, the
  "4 seconds apart" warnings, and the 269.744 s checkpoint write.

**So the campaign-wide confound I was braced for does not exist and prior OSv numbers stand.**

**Why the retraction matters more than the finding would have:** had it stood, I would have published
"every OSv number in this campaign was measured under a checkpoint storm Linux escaped" - a dramatic
claim, **in OSv's favour**, that was wrong, and one that would have partially explained away the 22x
gap. That is precisely the comfortable conclusion that deserves the most scepticism. **Third
self-retraction by an agent today**, and every one has been worth more than the claim it withdrew.

Now verified externally from the driver against the running guest (not read from a file), **16 values
byte-identical to the Linux arm**: max_wal_size 65536 MB, min_wal_size 2048 MB, shared_buffers
2097152 8kB, effective_cache_size 4194304 8kB, max_connections 400, checkpoint_timeout 900 s,
checkpoint_completion_target 0.9, fsync on, synchronous_commit on, full_page_writes on, autovacuum on,
io_method sync, log_checkpoints on, wal_sync_method fdatasync, data_directory /data/pg.

## Third time today an agent caught me proposing a merge whose scope I had not measured
I said "merge `fix/elf-object-cache-address-space`". The agent noted that drags in the **entire
aarch64 port lineage** (split-TTBR, GICv3 SGI, phys-map, RNDR) - wrong risk profile for an x86 arm,
and it would make any x86 result attributable to a large unrelated delta. It **cherry-picked**
`da3041f5d`, `6265b5ce5`, `7aa9c577c` onto repinned + fork-clone-scan instead. HEAD `e8f578a86`.

Same lesson as the other two instances: **scope is a property of the (base, branch) pair, and I keep
asserting it instead of measuring it.**

## Two one-second pre-boot checks now standing
    grep -c remap_segments_in_current_address_space core/elf.cc      must be 3
    grep -c 'PHONY: module build' apps/postgres18-musl/Makefile      0 => shadowed-build trap
plus verify postgres is in the image **by size** (~65 MB vs ~10 MB for a PG-free build).
