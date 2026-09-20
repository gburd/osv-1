# OSv MQ_COMPLETE A/B (candidate found: per-queue virtio-blk completion)

Same box/device/build as 1a. syncwrite t8/16/32, OSV_BLK_MQ_COMPLETE off (STEP 1a baseline) vs =1 (per-queue
completion, one completion thread per virtio-blk queue instead of a single global one). num_queues=4 on vblk1.
The boot line confirms it took: "OSV_BLK_MQ_COMPLETE: virtio-blk completion mode=per-queue num_queues=4".

| thr | OSv-off op/s | off flush/s | OSv-ON op/s | ON flush/s | ON mean_depth | ON/off op/s | Linux op/s | Linux flush/s | OSv-ON/Linux |
|----:|-------------:|------------:|------------:|-----------:|--------------:|------------:|-----------:|--------------:|-------------:|
| 8   |       11,652 |       3,222 |      12,763 |      3,495 |         1.43  |       1.10x |     31,529 |         8,335 |        0.40x |
| 16  |       15,992 |       3,001 |      21,996 |      4,291 |         1.70  |       1.38x |     44,133 |         5,283 |        0.50x |
| 32  |       24,079 |       2,579 |      32,097 |      3,621 |         1.48  |       1.33x |     55,370 |         4,480 |        0.58x |

## FINDING: the single virtio-blk completion thread WAS part of the ceiling. Per-queue completion lifts it.
- Flush rate rises +40-43% at t16/t32 with MQ on; op/s +33-38%. The gap to Linux narrows from ~0.40-0.50x to
  ~0.50-0.58x. This is a REAL, generic, upstream-conformance OSv fix (completion parallelism), NOT a PG hack.
- BUT a residual ~2x gap to Linux remains (OSv-ON 3621 flush/s vs Linux 4480 at t32; and t8 still 0.40x). So
  the completion thread was one serialization; there is a SECOND constraint.
- The residual signature: mean in-flight depth still ~1.5, mean issue_gap ~230-286us ~= one flush latency. So
  even with parallel completion, the issuer still advances at ~one-flush-latency cadence. Two possible causes,
  to be split by the transport control:
  (a) the OSv virtio-blk FLUSH round-trip latency itself is high (transport) -> each flush takes longer than
      Linux-direct's ~120us, so fewer complete per second even in parallel; OR
  (b) the zil issuer pacing (zl_parallel / commit-window / zl_last_lwb_latency-scaled timeout) caps the issue
      rate regardless of how fast flushes complete.
  Guest-Linux (same virtio-blk transport) discriminates: if guest-Linux flush latency ~= OSv's, it is
  transport (a); if guest-Linux still flushes fast, the residual is OSv issuer pacing (b).

## NOTE: OSV_BLK_MQ_COMPLETE defaults OFF. This is the #1509 fix, already in the m1-confirm base but env-gated
## off. STEP 1a baseline (no env) therefore ran with the SINGLE completion thread. Making MQ_COMPLETE
## default-ON is itself a shippable win (+33-38% op/s on this isolate). Candidate fix #1 for STEP 2/3.
