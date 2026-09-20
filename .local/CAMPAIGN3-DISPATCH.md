# Campaign 3 dispatch (2026-09-08): root-cause first, then re-benchmark

Four agents in parallel. **The key insight driving the plan: items 2, 3 and 4 of the request
(aarch64 >VU32, connection latency, aarch64 fork starvation) are probably ONE root cause.**

    Linux connect median          4.0-4.3 ms
    OSv aarch64 connect median    99.9-106.8 ms   (~25x)
    measured fork cost (earlier)  65-150 ms/fork  <- SAME ORDER

PostgreSQL forks one backend per connection, so **connect latency IS fork latency**, and 32
concurrent forks x ~100 ms serialized is exactly the observed VU32 starvation (99x
`autovacuum worker took too long to start`, pids to ~127k).

**And the fix already existed, unmerged.** `wip/fork-clone-scan` (`9b4ea6578` + `65279b938`) was
measured at **2.21x fork throughput** and 144.7 -> 65.4 ms/fork, but I verified `core/mmu.cc` on
BOTH benchmark bases still runs the linear `addr_is_shared` scan. Neither arm ever measured it.
Same failure mode as the dangling submodule pin: **work that exists but is not where it is
needed.** It merges cleanly (merge-tree RC=0, zero conflicts).

## Agents
| agent | scope | boxes |
|---|---|---|
| d55c4a8f | **Root cause**: fold the scan fix, measure fork cost directly, characterise the residual, fix `pagecache.cc` read_cache (4th fork-arena instance) | `Owner=agent-forkroot` |
| b9e2aea5 | **AIO** (#1): gap-list PG18 `io_method=worker` vs OSv, implement the minimum, measure sync-vs-worker | `Owner=agent-aio` |
| 7d0737f3 | **Firecracker (#5) + wedge backtrace (#6) + geometry/musl-matched Linux baseline (#7)** | `Owner=agent-fcmetal` |
| d35a8d8c | **Maintenance**: PRs, reviewer comments, deps, upstream-filed, plan, sync, tidy (local + LAN `arnold` + EC2) | no EC2 expected |

## Falsifiable prediction recorded in the brief
Folding the scan fix should cut connect median from ~100 ms toward a 40-65 ms floor, raise the
aarch64 VU32 ceiling, and improve NOPM **most at high VU and barely at VU8**. **If connect latency
does not move, the hypothesis is wrong** and fork is not the gap - stated explicitly so it can be
refuted. Also flagged: even at 65 ms/fork, Linux's 4 ms median is 16x better, so the scan fix is
**necessary but probably not sufficient**.

## Confound elimination (item 7)
The Linux reference was 16-vCPU VM + glibc vs OSv 32-vCPU metal + musl. Task C of 7d0737f3 runs
Linux **on m5d.metal restricted to 32 cores / 64 GiB with a musl-linked PG 18.6**, same configure
line, same ZFS properties, `max_wal_size=64GB`. Told to prove the restriction (`nproc` in the
cpuset, `free -g`) and to confirm musl linkage, and to **label glibc clearly if musl proves
impractical** rather than substituting silently.

## Corrections carried into every brief
- **No `zfs-2.4.1-osv` banner exists** - I invented it and briefed it repeatedly. `OpenZFS 5000` is
  `SPA_VERSION_STRING`, the pool format, identical for bsd_zfs and OpenZFS. Use build-time proof.
- **`state='active'` != on CPU.** It means "not on a registered wait event". Check a host-side CPU
  counter before calling anything CPU-bound; a "CPU-bound" verdict was wrong by 60x today.
- `max_wal_size=64GB` not 16GB; **`vucomplete` not `runtimer`**; rotate xtprof per run; the full
  HammerDB asset name; pool created once then import-only; the `module: build` target shadowed by
  `build/` can ship a **PostgreSQL-free image while reporting success**.
- **Do NOT `pkill` the wedged guest** before capturing the backtrace - that is how the last one was
  lost.

## Quota reality check (2026-09-08): the account is at 656 vCPU against a 512 quota

Agent 7d0737f3 flagged capacity pressure; I measured it and it is worse than either of us thought:

    192  c8g.metal-48xl      <- other project
    192  c7i.metal-48xl      <- other project
     96  m5d.metal           <- this agent
     64  4 x c5.4xlarge
     64  c7gd.metal
     16  2 x c7i.2xlarge
     16  r6id.4xlarge
     16  m5.2xlarge + c7g.2xlarge
    ---
    656 total

Two OTHER projects' 192-vCPU metal boxes account for 384 of that. AWS is evidently permitting
overage, but there is no room for three metal boxes. **So running Tasks C, B and A sequentially on
ONE metal box was necessary, not merely prudent**, and I told the agent not to attempt a second
metal launch - it could fail or evict someone else's work.

**Accepted consequence, stated explicitly rather than left implicit: if the clock runs out,
Firecracker (Task A) is what gets cut.** A complete geometry-and-libc-matched Linux baseline plus a
captured wedge backtrace beats three partial arms.

## The agent's memory-cap correction is better than my brief

I specified kernel `mem=64G`. That needs a reboot **and** would cap Tasks B and A on the same box -
a real problem I did not think through. cgroup v2 (`MemoryMax` + `AllowedCPUs` +
`AllowedMemoryNodes`) is also the closer analogue to a guest, which sees a hard memory ceiling
rather than a smaller machine.

Two things I asked it to nail down, because this is where hardware matching usually goes wrong:
1. **Prove the cap BINDS, not just that it is set**: `nproc`/`free -g` inside the cgroup,
   `memory.max`, `cpuset.cpus.effective`, `cpuset.mems.effective`, **and peak RSS / `memory.peak`**
   so we know whether 64 GiB was actually a constraint during the run. A limit never reached proves
   nothing.
2. **State the NUMA and SMT choice.** m5d.metal is 2-socket x 24c/48t, so the 32 CPUs must come
   from ONE socket with matching `AllowedMemoryNodes`, or we introduce a cross-socket confound the
   OSv guests do not have. Also **32 physical cores vs 16 cores x 2 hyperthreads matters a lot**
   when comparing against a 32-vCPU guest; either is defensible if stated, physical preferred.

## Cross-agent coordination
Told it that if `agent-forkroot` publishes a merged base with `wip/fork-clone-scan` before Task A
builds, **prefer it** - Firecracker numbers on the pre-fix base would be measuring a known-slow
fork path.
