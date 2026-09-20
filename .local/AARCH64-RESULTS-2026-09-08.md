# aarch64/Graviton3 TPROC-C: the first real throughput, and the wall

2026-09-08, agent 3c967111. Both boxes terminated, 0 orphans.

## Identity
osv **`761987065`** (`wip/aarch64-boot-plus-elf-as-fix`, pushed, G-signed) + **`5af7da0be`**
(rofs fix, pushed, G-signed) | apps **`b38b99cd`** | ZFS **OpenZFS pool v5000, META 2.4.2** |
PG **18.6** `REL_18_STABLE` aarch64-musl gcc 13.3.1, `io_method=sync`.
Guest 32 vCPU / 64 GiB, `Booted up in 275.67 ms`.

Substrate proven: `pg_relation_filepath` -> `/data/base/5/24588`; chain `/data` (ZFS) ->
`/dev/vblk1` -> `/nvme/pgdata.raw` -> `/dev/nvme0n1` "Amazon EC2 NVMe Instance Storage", ROTA=0,
**not tmpfs**; backing file grew **0 -> 8.8G -> 33G -> 82G -> 162G physical**. All 7 ZFS
properties local, ashift=12. fsync/synchronous_commit/autovacuum ON, `max_wal_size=65536MB`.
Driver->guest verified before load (`inet_client_addr=192.168.100.1`).

## THE MILESTONE: the sanity gate passes and plpgsql executes
The exact DO block that faulted 5/5 pre-fix now returns `rc=0` five times, and plpgsql really
runs (`NOTICE: plpgsql saw 415 pg_class rows`, `plpgsql | 1.0`). **All 6 TPROC-C plpgsql procs
ran under load for the first time in this project's history.**

## Throughput: peak 20,121 NOPM @ VU8, and VU32 is a hard ceiling

| VU | median NOPM | min-max | spread | gate |
|----|-------------|---------|--------|------|
| 8  | **20,121**  | 17,334-22,879 | 27.6% | FAIL |
| 16 | 17,192      | 14,637-19,746 | 29.7% | FAIL |
| 32 | no result x4 attempts | | | **ceiling** |

**4.9x below** the Linux 16-vCPU reference (99,504 NOPM @ VU8), same declining-after-VU8 shape.
VU96/128 not attempted - correctly pointless with VU32 unreachable.

## The VU32 ceiling is FORK STARVATION, not a harness artifact
Console repeats `WARNING: autovacuum worker took too long to start; canceled` **99 times**, probe
connections time out (8-30 fails/run), `LWLock:WALWrite` holds 31/34 backends, and PG logs
`too many clients already` with backend pids reaching **~127k** against `max_connections=400`,
i.e. enormous fork churn. **The guest cannot complete `fork()` under VU32 load**, which is why no
TEST RESULT is produced. It recovers when idle (`select 1` works, 200 warehouses intact).

The agent proved this was not the harness: its first attempt used `waittocomplete` (deprecated in
HammerDB 6.0), it caught that itself, re-ran VU32 with a `vucomplete` poll, and confirmed the
missing results are guest-side.

## Bottleneck: `LWLock:WALWrite` on an IDLE device - UNCHANGED

| VU | wait events | host %util | guest CPU |
|----|-------------|-----------|-----------|
| 8  | WALWrite **6-8 of 8** | 2.00 / 6.20% | - |
| 32 | WALWrite **31 of 34** | 2.12 / 0.00 / 0.00% | qemu 1219-1288% = **12.2-12.9 of 32 vCPU** |

w_await 0.09-0.20 ms. **Storage is not the limit; this is guest-side serialization, and the guest
cannot use even half its vCPUs.** Contrast: Linux same wait event with the device **73-93% busy**;
x86 OSv a third pattern entirely. `%util` remains the discriminator.

## Connect cost: the ~110 ms fork price is NOT the elf bug
Median **99.9-106.8 ms at VU8** with dlopen working, essentially unchanged from the prior run's
~110 ms/connect. Linux: 4350 samples, **zero >= 1 s**, worst 17.6 ms. So OSv is **~25x worse at
the median**, with 14-41 samples >= 1 s per run where Linux has none. That question is now
settled: fork/connect cost is an independent problem.

## max_wal_size=64GB: mechanism confirmed, diagnosis DISPROVEN as primary cause
`num_timed=4, num_requested=2`, four `checkpoint starting: time` at exact 15-min boundaries
(19:59/20:14/20:29/20:44), **zero WAL-triggered** (Linux: `num_timed=0`, 49/51 WAL-triggered).
**But spread stayed 27.6%/29.7%.**

The agent's attribution, which is better than my hypothesis: each timed checkpoint's *write phase*
runs **805-816 s of the 900 s interval**, so a checkpoint is writing ~90% of wall-clock and
"inside vs outside a checkpoint" is no longer a discriminator - it is always inside. Buffers per
checkpoint still swing 4x (322k/1378k/405k/379k), so checkpoint *weight* varies even when phase
does not. Residual otherwise **unexplained, and explicitly not speculated on**.

## Unplanned durability proof (again)
Two real crashes -> `redo done` in 39.3 s and 18.2 s, **200 warehouses and 59,997,155 order_lines
intact**, pool ONLINE with no data errors.

## Second failure, not diagnosed
`page fault outside application, addr 0x0000a0036b2c7000, PC: memset+140, ESR 0x96000044` via
`sys_fsync -> fsync` at VU32, pre-rofs-fix. Recorded, not chased.
