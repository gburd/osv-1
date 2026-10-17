# T4 audit: io_uring and block-driver "not implemented" branches

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

READ-ONLY audit. No files edited, nothing built, no PR opened. Verdict first; evidence below.
Anchors read at branch `wip/pg-rx-directwake` (matches `master` for every file cited — nvme.cc
last touched by 97463b2ba, unrelated discard path).

## (a) NVMe PRP ceiling — is it a real limit under PG/ZFS I/O sizes?

**No, not under today's PG-on-ZFS workloads — because the block layer splits above it. But the
driver carries a live off-by-one abort at exactly the ceiling that a different caller can hit.**

Computed ceiling (`drivers/nvme.cc:172`):

    dev->max_io_size = page_size << min(9, mdts)      // page_size = 4096

- `mdts >= 9`  → `4096 << 9` = **2,097,152 B = 2 MiB = 512 pages**.
- `mdts`  in 1..8 → smaller, controller-reported (`4096 << mdts`).
- `mdts == 0` ("no limit" per NVMe spec) → `4096 << 0` = **4 KiB**. The code reads 0 literally and
  produces a 4 KiB ceiling, not "unlimited". Harmless (just more splitting) but technically wrong.

The ceiling is enforced **above** the driver, so an oversized request never reaches the
"not implemented" path by failing — it is split first:

- `fs/vfs/kern_physio.cc:135` (`multiplex_strategy`): `if (len <= dev->max_io_size) strategy(bio)`
  else split into `ceil(len/max_io_size)` child bios, each `MIN(len, max_io_size)`.
- NVMe registers `multiplex_strategy` as its devop (`drivers/nvme.cc:85`), with `nvme_strategy`
  (`:54`) as the per-child strategy → `make_request` → `map_prps`.

So PG/ZFS 8 KiB–1 MiB I/Os (A2A config: `recordsize=8k`, ZFS vdev aggregation default 1 MiB =
256 pages) are **well under** the 512-page bound and split cleanly. The ceiling is invisible to them.

**The latent bug:** `drivers/nvme-queue.cc:157` guards the single-PRP-list case with
`assert(num_of_pages / 512 == 0)`, i.e. it aborts when `num_of_pages >= 512`. But `max_io_size`
at `mdts>=9` is **exactly 512 pages**, so a page-aligned 2 MiB split child (`num_of_pages == 512`)
trips the assert, and a *misaligned* buffer in a child just under 2 MiB (`first_page` partial +
511 + tail) reaches 513 pages and also trips it. In the kernel `assert()` is **never** compiled out
(`include/api/assert.h:9`, `_KERNEL`), so this is a hard panic, not a debug guard. The ceiling
(512 pages) and the list capacity (safe for ≤511) are off by one. One PRP list page holds 512
8-byte entries covering 512 list pages; with `prp1` covering page 1 the true safe max is 513
pages, but the `/512` assert cuts it to 511 — so the driver under-uses its own list and the
`max_io_size` it advertises is one page too large for its own guard.

Reachable today? No: nothing in our ZFS/PG path aggregates to 2 MiB. Reachable in principle? Yes —
raise `zfs_vdev_aggregation_limit` to 2 MiB, use ext4 with large readahead, or any direct caller
issuing a 2 MiB-aligned bio, and the box panics. It is a correctness landmine, not a throughput cap.

## (b) Per-branch table

| Branch (file:line) | What it rejects | Reachable in our configs? | Impact | Recommendation | Size |
|---|---|---|---|---|---|
| `nvme-queue.cc:157` assert `/512` + `nvme.cc:172` ceiling | 2 MiB-aligned / misaligned-near-2MiB NVMe child bio | **Latent** — not by PG/ZFS 8k–1M today; yes if aggregation/readahead ≥2 MiB | **Kernel panic** (assert always on) | **FIX** — the one worth doing | ~3 lines |
| `io_uring.cc:781` TIMEOUT "multishot variants not impl" | `IORING_OP_TIMEOUT` with abs/clock/multishot flags beyond `ETIME_SUCCESS` → `-EINVAL` | No (PG io_uring is storage read/write + poll, not timeout-multishot) | None | leave — honest `-EINVAL` | — |
| `io_uring.cc:1531` NOP128 / `URING_CMD128` SQE128 | 128-byte SQE ring geometry → `-EINVAL`/`-ENOSYS` | No (liburing uses 64-byte SQEs unless app opts into SQE128; PG does not) | None | leave — honest reject | — |
| `io_uring.cc:3065` register honest rejections | personalities, restrictions, FILES2/BUFFERS2, NAPI, ZCRX, BPF, resize/clone rings → `-ENOSYS` | No (PG/liburing default path needs none of these) | None | leave — correct per the comment (a lie corrupts state) | — |
| `nvme-queue.cc:315` "Operation not implemented" | NVMe bio_cmd other than READ/WRITE/FLUSH → `biodone(false)`+`ENOTBLK` | No — only READ/WRITE/FLUSH/DISCARD issued; DISCARD bypasses split and is handled elsewhere | None (clean error, not abort) | leave — honest rejection | — |
| `scsi-common.cc:238` "Report LUNS is not implemented" | SCSI REPORT LUNS returning non-OK → **fallback: enumerate LUN 0..max_lun** | **Not built** in PG/bench configs (needs `conf_drivers_virtio_scsi`/`pvscsi`; we boot virtio-blk/NVMe) | None, and it is a *fallback not a failure* | leave — the comment overstates; it degrades gracefully | — |

Reachability notes:

- SCSI: `scsi-common.o` builds only under `conf_drivers_scsi`, pulled in by `virtio_scsi` or
  `pvscsi` (`conf/profiles/x64/base.mk:9-12,34-37`, `Makefile:880`). Our PG/bench images boot
  **virtio-blk** (3 bench configs) or **raw NVMe** (A2A). virtio-scsi/pvscsi are off → scsi-common
  is not even compiled in. Lowest possible priority. Also note `exec_report_luns` *does* implement
  REPORT LUNS (`scsi-common.cc:209`); the "not implemented" comment labels only the error fallback,
  which synthesizes LUN 0..max_lun — graceful, not a gap.
- io_uring multishot: recv/accept/poll **multishot is implemented** (`exec_multishot`,
  `io_uring.cc:1631`, dispatched at `:1762`). The `:781` "multishot not implemented" text is scoped
  to `IORING_OP_TIMEOUT` only. PG's io_uring use (`io_method=io_uring`, A2A verdict) is block
  read/write + poll; it does not request timeout-multishot, SQE128, or any registered rejection.

## (c) Verdict

**One branch is worth fixing: the NVMe PRP `assert(num_of_pages / 512 == 0)` off-by-one at
`drivers/nvme-queue.cc:157`, paired with the `max_io_size` 2 MiB ceiling at `drivers/nvme.cc:172`.**
It is the only one that panics rather than returns a clean error, and the only driver gap on an
I/O path our configs actually traverse (raw NVMe in A2A). It is latent for current PG/ZFS 8k–1 MiB
I/O but a hard panic for any caller that aggregates to 2 MiB. Fix is ~3 lines: cap `max_io_size`
at 511 pages (`page_size * 511`, or `<< min(8,mdts)` with explicit `mdts==0`→cap handling), or
widen the guard to the true 513-page capacity and keep 512. Prefer shrinking the ceiling — it is
the conservative, allocation-free change and keeps the single-list invariant obviously true.

Everything else (`io_uring.cc:781/1531/3065`, `nvme-queue.cc:315`, `scsi-common.cc:238`) is an
honest rejection or a graceful fallback on a path our workloads do not hit — **leave as-is**. The
io_uring register/opcode rejections are deliberately correct: the surrounding comments argue (rightly)
that faking success would corrupt liburing/app state, which is worse than `-ENOSYS`.
