# Upstream PRs opened 2026-09-05 from the P2 (aarch64) agent's findings

All four are standalone generic OSv fixes, all OPEN + MERGEABLE + verified-signed,
each cherry-picked onto current upstream/master. None is PostgreSQL-specific;
PostgreSQL was only the workload that exposed them.

| PR | Fix | Impact |
|----|-----|--------|
| #1490 | aarch64: cover all of physical memory in the temporary phys map | any aarch64 guest with >~3 GB RAM wedged silently at boot |
| #1491 | aarch64: do not cap GICv3 SGI targets at 16 CPUs | any aarch64 GICv3 guest with >16 vCPUs aborted on the first IPI |
| #1492 | random: satisfy early /dev/random reads from RDRAND instead of blocking | any app reading /dev/urandom early could block forever (x86_64) |
| #1493 | aarch64: satisfy early /dev/random reads from RNDR (FEAT_RNG) | same, aarch64; stacked on #1492 |

## The /dev/urandom bug: why aarch64 PostgreSQL never worked

`random_read()` blocks in `randomdev_block()` when `!random_adaptor->seeded`. On a
freshly booted idle guest there is little entropy to harvest, so the reader can
wait indefinitely. PostgreSQL calls `pg_strong_random()` -> `read(/dev/urandom)`
at startup, so the postmaster parked on its very first read and never logged a
line.

gdb evidence: all CPUs idle in `wait_for_interrupt`, 149 threads, exactly one
`postgres` thread `waiting`, unwinding
`reschedule_from_interrupt / schedule() / thread::wait() / synch_port::_msleep /
randomdev_block / random_read / device_read / vfs_file::read / sys_read / pread64`.

The asymmetry that explains the whole aarch64 history: the driver already avoided
this on x86_64 by answering the read from RDRAND, but that path is gated
`#ifdef __x86_64__` + `processor::features().rdrand`. aarch64 had no hardware
path, so it always fell into the blocking sleep. Same image, same app: works on
x86_64, hangs on aarch64.

The aarch64 fix uses Arm's architectural equivalent, FEAT_RNG
(`ID_AA64ISAR0_EL1.RNDR`, bits 63:60, providing RNDR/RNDRRS), exactly as x86 uses
RDRAND. Validated: PostgreSQL 18.6 now reaches "database system is ready to
accept connections" on aarch64.

## Why #1492 had to be split out first

The x86 RDRAND-in-`random_read` fix was NOT on master and NOT in any PR: it was
buried inside a fork mega-commit (`858dd78f2`, "fork: cross-AS coherence for
epoll containers, rcu_defer wait_records, per-backend pid + SIGURG latch
routing..."). That is why the aarch64 commit would not cherry-pick onto master.

The hunk is entirely self-contained (its own comment even says "independent of
fork"), 31 added lines, applies clean to master. So it was extracted as #1492 and
the aarch64 fix stacked on top as #1493. Two clean reviewable PRs instead of one
unmergeable one.

LESSON: generic fixes get swept into large feature commits and then never reach
upstream. Worth auditing the other fork mega-commits for the same pattern -
self-contained non-fork fixes that could be extracted and upstreamed now.

## Retracted by the agent

Its earlier "seed_copy hangs reading /data-seed" report was WRONG and it retracted
it: seed_copy always worked; the guest was simply powering off after the last
command, proven with --noshutdown. Nothing wrong with ramfs or rofs. My redirect
away from the fs=rofs rebuild was right for the wrong reason - the real bug was
/dev/urandom blocking, not the filesystem.
