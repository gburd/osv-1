# "The 19-second stall might be ZFS, not OSv" - tested and REFUTED

2026-09-08. Agent 974ed15b raised a genuinely alarming hypothesis at the end of its run. It
deserved a real test, and the data to run that test already existed.

## The hypothesis

From the other session's `log_checkpoints` on **Linux/ZFS**, PG 18.6, same
`recordsize=8k / compression=off / logbias=latency` config:

    write=      sync=       total=      longest sync file
     90.599 s    2.651 s     94.531 s    1.468 s
    149.633 s    0.151 s    149.918 s    0.144 s
    256.299 s   19.332 s    276.220 s    7.303 s     <-- 19.3 s of sync time
      1.145 s    3.607 s      4.832 s    2.399 s

Three of four checkpoints had `sync` > 1 s, one hit **19.332 s** with a single file stalling
7.3 s. Since a ~19-second stall is exactly what the OSv connect probe originally exposed, the
agent proposed that the OSv stall might be **inherited ZFS checkpoint-fsync behaviour rather
than an OSv defect**. It correctly labelled this a strong hypothesis, not a conclusion,
because it could not run the connect probe to close the loop.

## The test: the completed Linux arm already ran that probe

`bench-linux/LINUX-BASELINE-RESULTS.md` (agent c8742b2c, same instance type, same ZFS
properties, same PG 18.6, same `io_method=sync`) has BOTH instruments in the same run:

    Linux/ZFS checkpoint fsync stalls   : PRESENT. NEWORD `worst max` 1.3-4.9 s per run,
                                          and it explicitly "tracks checkpoint fsync stalls"
    Linux/ZFS connect probe             : 4350 samples, ZERO failures,
                                          **ZERO samples >= 1 s**, worst single sample 17.6 ms

So on Linux the ZFS checkpoint stall **does** hit in-flight queries and **does not** hit the
connect path at all. Whereas on OSv the connect path is where the stall appeared (19,327 ms
worst pre-fix on x86; 262 ms median on aarch64 vs Linux's 4.0-4.3 ms).

**Conclusion: the two phenomena are distinct.**
- Checkpoint fsync stalls are real, are ZFS-inherited, and hit QUERIES on BOTH platforms.
  That part of the agent's finding stands and is worth acting on for both.
- The OSv CONNECT-path stall is NOT explained by them, because the identical ZFS behaviour on
  Linux produces zero connect samples over 1 second across 4350 probes.

## Independent corroboration from the fix history

The OSv 19-second stall fell to **7,782 ms** when `ae077860c` (a **virtio-blk completion
deadlock** fix) landed, and further with the fault-side AS-lock fixes. A stall inherited from
ZFS checkpoint fsync would not respond to a virtio-blk completion-path change. Two
independent lines of evidence therefore point the same way.

## Why this was still worth the agent raising

The magnitude coincidence (~19 s on both) is striking, and if it HAD been the same phenomenon
we would have spent effort chasing an OSv bug that was really a ZFS tuning issue. The
hypothesis was cheap to raise and cheap to refute, and refuting it strengthens the OSv
finding rather than weakening it. This is the correct pattern: propose a mechanism, then look
for the measurement that discriminates - here, "does the same ZFS behaviour on Linux affect
the connect path?"

## Actionable item that survives
Checkpoint fsync stalls ARE hurting query latency on both platforms under this config, and
`checkpoint_timeout=15min` never fires (49 of 51 checkpoints WAL-triggered every ~72 s). The
fix for both platforms is the same and already identified: raise `max_wal_size`, and split WAL
onto `recordsize=1M, logbias=throughput` (ZFS costs 3.9x on the 8 KiB dsync pattern:
56.1 MB/s vs 218 MB/s raw).
