# ZIL post-commit wakeup fan-out: localize + fix

BOX: **i-08d7381c36de61059** (m5d.metal, us-east-2a, Owner=agent-zilwake)
Host: Debian 12 (bookworm), ami-0dc1629a58a7d6458, qemu 7.2.22 (native, /dev/kvm)
Guest target: 32 vCPU / 64 GiB, ZFS pool on raw instance-store NVMe (virtio-blk)
Branch: gh-fork/bench/zilwake @ d89f88689 (m1-confirm base + probe + Lever-1)

## Objective
Confirm/refute the serial single-waker fan-out in zil_lwb_flush_vdevs_done() as
the M1 throughput ceiling, and A/B the fix. NO postgres, NO HammerDB - just the
syncwrite concurrent durable-write isolate + the zil probe.

## STATUS (updating as it runs)
- [x] Box launched, Debian 12, qemu 7.2.22 native, /dev/kvm present, 4x 838G NVMe.
- [x] Probe patch 0034 written (gethrtime N/lockhold/wakeloop + Lever-1 OSV_ZIL_WAKE_UNLOCKED)
      VERIFIED to apply on the pinned 2.4.2 submodule (6330a45b).
- [x] Makefile fixed: apply patch series one-at-a-time w/ --recount + loud skip log
      (the single atomic `git apply <all>` silently applied NOTHING when any
      dependent patch failed pre-flight - the swallowed-error trap). Only 0032
      (ARC-OOM sync shrinker, irrelevant to this bench) skips.
- [x] Branch pushed to gh-fork/bench/zilwake.
- [x] Native Debian build OK (~7 min, make -j96, no container).
- [x] VERIFY probe in built zil.c (grep=9) + zilwake_dump exported as T in libsolaris.so.
- [x] Boot test: -M q35 HANGS on qemu 7.2 right after virtio-blk init (before the
      bench main() prints) - the q35 AHCI regression the directive warned about is
      NOT fully absent on Debian's 7.2.22 for THIS device layout. -M pc BOOTS AND
      RUNS cleanly. Using -M pc.
- [x] SMOKE (t=8, 8s, MQ_COMPLETE=1, baseline): commits BATCH - mean_N=3.75 max_N=8,
      mean_fanout=21.6us, wakeloop=17.5us (81% of fanout), lockhold~=fanout.
      Hypothesis NOT refuted; serial wake loop dominates AND is under zl_lock.
- [x] STEP 1 measure: N + fan-out time vs threads=8/16/32 (fix OFF), reps=3 secs=20.
- [x] STEP 2 A/B: Lever-1 ON vs OFF at threads=16/32 (also MQ on/off + nofsync control).
- [x] VERDICT: mechanism real (N batches, fan-out serial + lock-held) but Lever 1 is a
      throughput NULL (+1.8% t32, noise); the zl_lock hold is not the gate. Real wake lever
      was per-queue completion (already on). Residual ceiling = per-commit round-trip;
      fanouts/s pinned ~3000/s => LWB pipeline depth ~=1 is the next suspect.
- [x] Lever 1 filed standalone (probe-free): gh-fork/bench/zil-wake-unlocked @ 1fe51340c,
      on contention-reduction merit, NOT a throughput claim.
- [x] Probe baked into bench image (bench/zilwake); zilwake_dump exported.
- [x] Box TERMINATED, 0 orphan instances (state=terminated), 0 orphan volumes ([]).
