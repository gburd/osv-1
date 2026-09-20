# The large-page fork fix is NOT ISA-specific: x86 confirmed, 8.61x, mechanism matched to 0.1%

2026-09-09/10, agent ec362954. Both boxes terminated, 0 orphans.

## Deliverable 1: DONE, and it is the cleanest result of the campaign

Branch `gh-fork/wip/pg-x86-forkroot-largeshare` @ **`42aeb163b`**, 7/7 cherry-picks clean, 11 commits
all `%G?`=G, reported on #1456 (issuecomment-5612901646).

Identity: osv `42aeb163b` | apps **`5cb1903`** | ZFS `6330a45b0` (zfs-2.4.2) | `REL_18_STABLE` | PG
18.6 | `--without-icu --without-zlib --without-readline --without-libxml --without-lz4 --without-zstd`,
`CC=musl-gcc`.

Connect A/B, **same binary, interleaved across 8 boot pairs**, with `FORKFLAG` proving binding each boot:

    OSV_FORK_LARGE_SHARE=1   n=53  median  6.607 ms   min 5.615  max 9.121
    OSV_FORK_LARGE_SHARE=0   n=11  median 56.870 ms   min 55.785 max 58.212
                                          8.61x, delta 50.26 ms

**And the mechanism matched aarch64 to 0.1%**, which is what makes this conclusive rather than
suggestive:

              n_ptes before -> after      ratio
    aarch64   4,445,585 -> 132,497        33.6x
    x86       4,445,538 -> 132,962        33.4x

`n_ptes` is hardware-independent, so the near-identical counts prove the same code path does the same
work on both ISAs. **The fix is architectural, not ISA-specific.**

My prediction (78 -> ~4 ms) was wrong on both endpoints while right on the ratio: measured 56.9 -> 6.6.
Cause is legitimate and was flagged in advance - `m5zn.metal` is higher-clocked than the m5d-class
baseline, and the probe includes a TCP round trip. **The counters are the durable evidence; the
milliseconds are host-specific.**

## Deliverable 2: NOT DELIVERED, and blocked by a real bug rather than substrate

**`__stack_chk_fail(): Stack overflow detected` after 1-5 cumulative `fork()` calls.** Characterised
properly before giving up, which is why this is a finding and not a failure:

- **Not from the ports**: both A/B arms crash identically, 6/6 boots. `OSV_FORK_LARGE_SHARE` changes
  fork *cost*, not crash behaviour.
- **Not query work**: one held connection did 500k inserts + a full update + 71k deletes +
  `VACUUM ANALYZE` + `CHECKPOINT` with zero crashes. **The next NEW connection killed it.**
- **Not concurrency**: from a fresh boot, 8/8, 16/16, 32/32 and **96/96** simultaneous connections all
  succeeded.
- **Not `shared_buffers`** (16GB/1GB/128MB -> 2/4/2 forks) and **not stack depth** (4x kernel stack
  moved 1-2 -> 4 forks only).

So it is **cumulative fork count**, independent of load, concurrency and memory sizing. It correctly
refused to report NOPM from a guest that dies mid-run.

## Three of my premises corrected, all verified by me

1. **My specified apps pin re-armed the trap I warned about in the same brief.** Both bases pin
   `b38b99cd` where `grep -c '.PHONY: module build'` = **0**; the fix `5cb1903` is its child. I have
   since pushed `wip/pg-v26-faultfix-repinned2` (`5d1ef07c2`) re-pinning it at source.
2. **`conf_zfs=openzfs` does NOT select the OpenZFS image path - only `--use-openzfs` does.** Verified:
   `scripts/build:176-177` sets `vars[use_openzfs]`, and `:340`/`:372` gate the host-side image build on
   it. Without it, assembly boots a guest and pushes 112 MB over `cpiod`, which wedged 4/4. Also
   `scripts/upload_manifest.py:194` **hardcodes `-m 4G`**, so `zfs_builder_mem` is inert. `fs=rofs`
   builds host-side and works.
3. **The image-size check does not fit this tree**: `fs=rofs` gives **119 MB / 6 entries**, not
   63-65 MB / 7. The PG-free signature here is **~8 MB**. My check was calibrated on a different fs.

New substrate facts: **`vhost=on` leaves the guest unreachable** (binds the IP, logs `eth0:`, never
answers ARP) - use `vhost=off`. And **`ashift` needs `zpool get`, not `zfs get`**.

## Honest gap it stated rather than papered over
No ZFS-backed PGDATA run: `seed_copy` fails **EACCES at depth 2** under a mounted OpenZFS pool, 74/74.
It had a theory (root vnode `v_mode` unset at `zfs_vfsops.c:637`) but **the depth-2-only distribution
refutes it, so it asserted no mechanism.** The A/B above used the baked ramfs `/data` - legitimate for a
fork/connect probe, and it says explicitly that this would NOT have been acceptable for NOPM.
