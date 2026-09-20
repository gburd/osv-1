# Two agents stalled; work recovered rather than restarted from zero

2026-09-07. Both long-running agents hung mid-`bash` call and stopped logging. Diagnosed
from tool-use rate plus transcript timestamps, then verified against their live boxes.

## Detection: tool-use rate, not elapsed time

    974ed15b  Linux/PG baseline   19.5 h elapsed, only  18 tool uses, last log 12:18
    924205f9  q35 boot fix        16.1 h elapsed, only  33 tool uses, last log 15:50

Elapsed time alone is not evidence of a stall (a legitimate benchmark can run for hours).
**The signal is elapsed-vs-tool-uses**: 18 calls in 19.5 hours means the agent is blocked,
not working. Both transcripts end on an assistant `toolCall` with no matching result, i.e.
each is blocked inside a foreground `bash`/ssh that never returned.

Root cause in both cases: **a long foreground command with no bounded timeout.** Both
briefs said to use `nohup`+poll and bounded timeouts; neither agent did it for the one
command that mattered (HammerDB install/schema build; an in-container OSv build).

## Recovered state (checked the boxes directly before restarting)

**Linux arm** (`osv-bench-linux-db` + `osv-bench-driver`):
- ZFS pool `pgdata` 278G ONLINE, 0% frag
- PostgreSQL **16.15** running and reachable
- HammerDB 6.0 installed at `~/HammerDB-6.0/hammerdbcli`
- **NOT done: the schema.** `count(*) from warehouse` -> relation does not exist; pool holds
  only 42.8 MB. It died immediately before `buildschema`.

**q35 arm** (`osv-q35-fix`):
- kernel **built successfully**: `loader.elf` 69,797,264 B and `loader.img` 4,521,984 B
- died at the IMAGE UPLOAD step, not the build:
  `scripts/upload_manifest.py:55 cpio_send -> BrokenPipeError: [Errno 32] Broken pipe`

So in both cases hours of setup were salvageable and neither needed a fresh box.

## Restarted with the completed work as the starting point

- `c8742b2c` Linux baseline: told exactly what is already done, to re-verify the config
  cheaply rather than rebuild, and that the schema is the first real step.
- `8bd9e217` q35 fix: told not to rebuild, that the failure was upload-not-build, and that
  a virtio-blk-era hang needs neither PostgreSQL nor ZFS - so it can use `-kernel
  loader.elf` with a trivial image and skip the step that broke.

## Guards added to both new briefs
1. **Bounded timeout on every ssh; `nohup`+poll for anything long.** Stated as the specific
   reason the predecessor failed, not as generic advice.
2. **A wall-clock budget with a defined fallback**: at ~4 h (Linux) / ~3 h (q35), stop and
   report what exists. "A complete VU 8/16/32 with 3 repeats beats a half-finished
   5-level sweep."
3. **Cut VU levels, not repeats**, if scope must shrink - single-run numbers are unusable
   given the 15% spread gate.
4. Config fidelity is **re-verified, not assumed**, since the predecessor's setup was never
   validated: full `zpool get`/`zfs get`/`SHOW` paste plus a PGDATA-on-ZFS-on-NVMe proof,
   and permission to destroy/recreate the pool if `ashift != 12` (safe: no data yet).

## Cross-arm question added while the box is already paid for
The Linux arm is now asked whether it shows the **`LWLock:WALWrite`** signature the OSv
aarch64 arm found (20-31 of 32 backends waiting with the NVMe 98% idle), and to measure raw
device capability (`dd` 1 MiB `oflag=direct` vs 8 KiB `oflag=direct,dsync`). If Linux shows
the same wait signature, the ceiling is PostgreSQL's WAL design rather than an OSv defect -
which would substantially change what the platform work should target. Cheap to collect and
directly decision-relevant.

Also flagged for the report: the Linux box runs **PG 16.15** while the OSv arms run **18.6**.
Stated as an explicit cross-comparison caveat rather than hidden.
