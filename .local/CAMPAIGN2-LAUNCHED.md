# Campaign 2 launched (2026-09-08), blocker fixed first

> **CORRECTION 2026-09-09: "no scaling region on Linux either" was a 16-vCPU SATURATION ARTIFACT.**
> On matched geometry (32 logical CPUs, bare metal, musl) Linux scales strongly:
>
>       VU8 232,139 | VU16 397,160 | VU32 527,415 | VU64 627,652 (PEAK) | VU96 581,061
>
> Peak at **VU64, 2.7x its own VU8 figure**. The old 16-vCPU VM reference peaked at VU8 and declined
> monotonically, and I generalised that shape into "PostgreSQL/TPROC-C has no scaling region on this
> workload, on any platform." **That was wrong.** The platforms differ in SHAPE, not only level:
> Linux converts added concurrency into throughput up to VU64; OSv converts it into queueing
> immediately (peaks at VU8 and declines). The gap therefore WIDENS with concurrency:
> 5.3x at VU8, 10.5x at VU16, 15.2x at VU32, 22.1x at VU64, 22.3x at VU96.



The blocker that produced ZERO NOPM on both OSv arms in campaign 1 is fixed
(`.local/FORK-DLOPEN-AS-CACHE-BUG.md`): `elf::program`'s object cache is process-global while
PT_LOAD mappings are per-AS, so any second consumer of a dlopened library faulted in
`dynamic_tag`. Fix on `gh-fork fix/elf-object-cache-address-space` (`da3041f5d`, `6265b5ce5`),
filed on **#1456**, runtime-validated on aarch64.

## Agents
| agent | task | boxes |
|---|---|---|
| d4454474 | **x86 fix validation THEN x86 benchmark** (KVM + Firecracker) | m5d.metal + c5.4xlarge driver, `Owner=agent-x86bench` |
| 3c967111 | **aarch64 benchmark** on the validated fix | c7gd.metal + own x86 driver, `Owner=agent-armbench` |

The x86 agent is **gated**: Task A is the runtime validation (pre-fix fault + post-fix pass on
x86_64, including the AS0-as-second-consumer case), and it is told to STOP and report if that
fails rather than proceeding to Task B or trying to fix the fix.

## Corrections from campaign 1 folded into both briefs
- **`max_wal_size=64GB`, not 16GB.** At 16GB `checkpoint_timeout=15min` never fired
  (`num_timed=0`, 49/51 checkpoints WAL-triggered every ~72 s, 4-5 per 5-minute window at
  arbitrary phase), which STRUCTURALLY caused the 30-35% spreads. Both arms must report
  `num_timed` and whether spread dropped under 15% - that is a result, not bookkeeping.
- **`io_method=sync` on every arm**, matching the Linux reference, because OSv's AIO path is
  incomplete and Linux/PG18 defaults to `worker`.
- **Result identity is the 6-tuple** (osv SHA, apps SHA, zfs banner, PG branch, PG version,
  configure line), in the report header.
- **Create the ZFS pool ONCE, then import-only**, or `zpool create -f` in the boot chain wipes
  the dataset each boot and every "repeat" measures a cold database.
- **The full HammerDB asset name** (`HammerDB-6.0-Prod-Lin-UBU24.tar.gz`), because my earlier
  paraphrase "the RHEL9 build" sent agents to 404s.
- Both told the **historical "aarch64 crashes at VU128" datum is VOID** (it was this bug, at 1
  connection) and to find the real ceiling.
- Both told **`%util` is the discriminator, not the wait-event name**: Linux showed
  `LWLock:WALWrite` on 55/64 backends with the device 73-93% busy (PostgreSQL's WAL design),
  while OSv showed the same queue with the device 98% IDLE (an OSv-side cost). Re-testing that
  is the single most decision-relevant measurement in the campaign.
- Both told to use **`mincore()` not `msync()`** for any VMA-presence probe.

## Standing comparison target
Linux/PG18.6, ZFS-on-NVMe, 16-vCPU VM, fsync+synchronous_commit+autovacuum ON:
peak **99,504 NOPM @ VU8**, declining after (no scaling region); connect probe 4350 samples,
**zero >= 1 s**, worst 17.6 ms, median 4.0-4.3 ms. Residual confounds to state, not bury:
16-vCPU VM vs 32-vCPU metal partition, and glibc vs musl.

## Memory note
`memelord` MCP is **down** (`Connection closed (GenericFailure)` on connect, server-side), so the
durable lessons were written to `.local/MEMORY-BANK-2026-09-08.md` instead, tagged with the
memelord `type` each entry should be filed under. **Re-file them when the server is healthy.**

## Provenance fixed mid-flight: the x86 benchmark base was still broken

Checked the three bases in play the moment the arms launched:

    fix/elf-object-cache-address-space   apps=b38b99cd  ok
    wip/aarch64-forkcow-signed           apps=b38b99cd  ok
    wip/pg-v26-faultfix                  apps=57c60798  <-- DANGLING

So the aarch64 arm was clean but the **x86 arm's base still carried the dangling pin**, which
would have made this campaign's x86 numbers as unattributable as campaign 1's. Fixed rather
than worked around:

**`gh-fork/wip/pg-v26-faultfix-repinned`** (`124caf42a`, G-signed) = `wip/pg-v26-faultfix` with
`apps` re-pinned to the published `b38b99cd`. Pushed to a NEW branch, never force-pushed over
the original. Verified end to end instead of assuming:

    git clone --branch wip/pg-v26-faultfix-repinned --single-branch .../osv-1.git
    git submodule update --init apps   ->  RC=0
    apps resolved to b38b99c  "postgres18-musl: -mno-outline-atomics on aarch64"

Relayed to the x86 agent with instructions NOT to redo work if it had already substituted
manually - only to record the exact `apps` SHA in the identity tuple, since that is what
actually matters.

### A near-miss worth recording
My first push printed `error: failed to push some refs` and my one-liner echoed "pushed"
anyway, because the `echo` ran regardless of the exit status. I nearly recorded a failed push
as a success. Re-running with an explicit `refs/heads/...` refspec worked. **This is the same
class of error as reading `$?` after a pipe: a status-swallowing shell construct producing a
confident wrong conclusion.** Third instance this session of an instrument or harness, rather
than the code under test, nearly generating a false result.

## Blocking brief error: the elf fix and the aarch64 boot fixes are DIVERGENT lineages

Agent 3c967111 caught this before benchmarking, having measured three boot outcomes on
`fix/elf-object-cache-address-space` at c7gd.metal with qemu 8.1.3:

    smp=32 mem=2G  ->  Assertion failed: smp_idx < max_sgi_cpus
                       (arch/aarch64/gic-v3.cc send_sgi:671), via sched::cpu::load_balance. HANG.
    smp=1  mem=4G  ->  silent hang right after the OSv banner, no assert, no further console
    smp=2  mem=2G  ->  boots fine, "Booted up in 124.41 ms"

So the briefed base **cannot boot the 32 vCPU / 64 GiB geometry the benchmark requires**, for two
independent reasons orthogonal to the elf fix:
1. **GICv3 SGI targets capped at 16 CPUs** -> any smp>16 asserts.
2. **`setup_temporary_phys_map` aliases a boot identity L1 covering only 4 GB** -> any guest with
   >3 GB RAM wedges in the exception vector before a handler exists.

Verified by me:

    4baaaf1b6 / 6130ae72d / c929f2a51  on fix/elf-object-cache-address-space  -> NO, NO, NO
    da3041f5d / 6265b5ce5             on wip/aarch64-p2                      -> NO, NO

    fix/elf-object-cache-address-space  gic-v3.hh:282  max_sgi_cpus = 16
    wip/aarch64-p2                      gic-v3.hh:288  max_sgi_cpus = sched::max_cpus

Neither lineage contains the other. **But they merge cleanly**: `git merge-tree --write-tree
--messages wip/aarch64-p2 fix/elf-object-cache-address-space` exits 0 with zero CONFLICT lines,
which I checked so the agent would not have to hand-resolve. Approved its plan (p2 + the two elf
commits) and asked it to **push the merge branch to `gh-fork`** rather than leave the only capable
tree on a box about to be terminated.

### A claim of mine that this corrects
I have repeatedly said #1490/#1491/#1493 are "already cherry-picked onto the aarch64 lineage".
True of `wip/aarch64-p2`, **false of the elf-fix branch**: I conflated "the aarch64 lineage" with
"any aarch64 branch". The elf fix was built on `wip/aarch64-forkcow-signed`, which never carried
them.

### Unplanned value for two open PRs
The agent's measurements are the best evidence yet that **#1490 and #1491 are hard prerequisites,
not nice-to-haves**: any aarch64 guest above 16 vCPU asserts, and any guest above ~3 GB RAM wedges
silently before a fault handler exists. Neither had been demonstrated at that granularity. Asked
for it in the report so it can be added to those PRs.

## max_wal_size=64GB: my mechanism prediction CONFIRMED, my variance diagnosis INCOMPLETE

Measured on aarch64 (agent 3c967111):

    pg_stat_checkpointer: num_timed=4, num_requested=2
    console: 4x "checkpoint starting: time" at exact 15-minute boundaries
             ZERO WAL-triggered checkpoints during the sweep
    (Linux at max_wal_size=16GB was: num_timed=0, 49 of 51 WAL-triggered every ~72 s)

So raising `max_wal_size` did exactly what I predicted: timed checkpoints now dominate and the
WAL-pressure treadmill is gone.

**But spread is STILL over the gate: VU8 27.6%, VU16 29.7%.** So checkpoint phase was **not the
whole cause** of the 30-35% run-to-run variance. My diagnosis was incomplete rather than wrong:
the mechanism changed as predicted, the variance did not resolve.

Asked the agent to report both halves plainly and, if cheap, to say what the residual correlates
with (autovacuum activity, ARC warmup across repeats, guest scheduling). Explicitly told it that
**"the checkpoint hypothesis is disproven as the primary cause and the residual is unexplained"
is a good result** - better than a speculative attribution, and it stops the next person assuming
the problem is solved.

This is worth remembering as a pattern: a mechanism can be confirmed at the level it was proposed
(checkpoints ARE now timed, not WAL-driven) while failing to deliver the outcome it was proposed
to explain (the variance). Confirming the mechanism is not the same as confirming the diagnosis.

## Milestone
The same run produced **NOPM at VU8 and VU16 on aarch64 - the first real aarch64 TPROC-C
throughput in this project's history.** Every prior attempt died in the dlopen path before the
timed window opened. Even a partial sweep is a first.
