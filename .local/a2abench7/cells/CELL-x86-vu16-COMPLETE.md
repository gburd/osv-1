# x86_64 QEMU-KVM, VU16, 3 settled repeats

Run by the operator after agent e0f833b9 completed with its boxes still live. Same guest, same
dataset, same protocol as the VU8 cell - the guest was never rebooted between cells.

## Quiesce, before measuring (the protocol the agent established)
    checkpoint 1: 0s   checkpoint 2: 1s   checkpoint 3: 0s
No dirty backlog, so these are settled-state numbers rather than checkpoint-contaminated ones.

## Result
    s1 41,406   s2 39,997   s3 38,835
    median 39,997   min 38,835   max 41,406   spread 6.4%  (well under the 15% flag)
    Linux VU16 ~397,000  =>  9.93x behind

Connect probe on s1: median 54.8 ms, p95 115.9, p99 147.4, max 158.3, **0 samples >=1s, 0 errors**.

## Identity
osv `cbbf74e7` (stack_guard=3, OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2), apps `3f93f43`,
PG 18.6 x86_64-pc-linux-musl, `io_method=sync`, 200 warehouses / 19 GB on ZFS-on-NVMe,
ashift=12 via `zpool get`, no tmpfs, all 12 GUCs `source=command line`.
