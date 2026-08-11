---
name: osv-fair-benchmark
description: Run a fair, apples-to-apples OSv-vs-Linux performance benchmark (PostgreSQL or any server) that produces trustworthy parity numbers instead of conflated ones. Encodes the hard-won fairness rules learned across this project's parity campaign: both native (no QEMU) or both guests on the same host, matched storage (ZFS-vs-ZFS never ZFS-vs-ext4), matched instance type / config / workload, real network (not loopback), 0-failed gating, and a config-match proof. Use whenever comparing OSv to Linux (or A/B-ing an OSv fix) and you need a number you can defend. Triggers on: "benchmark OSv vs Linux", "is OSv at parity", "matched A/B", "apples-to-apples", "did the fix help".
---

## Overview

A comparison is only trustworthy if the *only* variable is the thing under test. This project repeatedly produced **conflated** OSv-vs-Linux numbers (OSv-on-ZFS vs Linux-on-ext4; OSv-in-QEMU vs Linux-native; loopback vs real NIC) and had to throw them away. This skill is the checklist that makes a run defensible.

**The one rule:** hold everything identical except the single variable (the OS, or the OSv fix on/off). If you can't hold something identical, name it as a caveat in the result — never bury it.

## The fairness traps (each one burned this project at least once)

1. **Storage: ZFS-vs-ext4 is NOT fair.** ext4 is materially faster than ZFS, especially on RW/fsync. If OSv runs ZFS, Linux MUST run OpenZFS too, configured identically. Comparing OSv-ZFS to Linux-ext4 unfairly flatters Linux on RW. (Linux-ZFS: Ubuntu 24.04 ships `zfsutils-linux` (OpenZFS 2.2.x) in-repo; AL2023/Debian ZFS-DKMS often won't build against a too-new kernel. Use Ubuntu.)

2. **QEMU tax: OSv-in-QEMU vs Linux-native is NOT fair.** Either both native on the same instance type (no QEMU), OR both as guest VMs on the same metal host with *identical* qemu invocation. Never OSv-guest vs Linux-bare-metal. QEMU's emulated virtio single RX queue is itself a bottleneck that doesn't exist natively.

3. **Loopback hides the receive path.** Drive the workload from a *separate* same-VPC/same-SG instance over the real NIC (ENA native, or the vhost tap IP in QEMU). `pgbench -h 127.0.0.1` bypasses the RX path being measured and gives meaningless numbers. Confirm the driver connects to the guest's real IP (e.g. the tap IP `192.168.100.2`, not loopback).

4. **Single-queue for both (QEMU).** If comparing in QEMU, give BOTH guests the same NIC queue config (single-queue vhost tap, no `mq=on`/`queues=` on one side only). An MQ leg is fine as a *separate* labeled leg, not mixed into the matched baseline.

5. **Instance type / config / workload must match.** Same instance type, same PG config (shared_buffers, max_connections, huge_pages, synchronous_commit, io_method), same scale factor, same concurrency sweep, same rounds.

6. **A measured null result is data, not failure.** If a fix doesn't move the number, report it honestly and let the next lever be chosen by measurement. This project ruled out 8+ hypothesized levers this way with zero false wins. Never claim "parity" or "the fix works" without a pasted matched table.

## Prerequisites for a native OSv-vs-Linux run (the blockers this project fixed)

Native OSv+PG under concurrent load was impossible until two fixes landed. If a native run stalls, check these first:

- **ENA inbound TCP on Nitro** (PR #1471, `drivers/ena` RSS indirection table must point at RX queue ids `ENA_IO_RXQ_IDX(i)` (odd indices), + `drivers/nvme` cap IO queues to `msix_get_num_entries()-1`). Without it: ARP answers but inbound unicast TCP is silently dropped at >= the vCPU count that exhausts the MSI-X table.
- **W2 fork coherence** (the shared-anon page must be fork-COW-coherent: `mm: lock-free RCU shared-anon fork page registry` `746e5bcd9` + `mm: shared-anon fork write faults skip the AS-wide write lock` `dad77b7fa`, on the `integ/pg-fork-zfs` #1458 stack). Without it: a forked PG backend `memcmp`-reads a non-coherent shared-anon catalog page -> `memcmp+30` page-fault abort on the 2nd connection. LESSON: never branch PG work off a tip missing these two mmu commits (that was the `pr/rss-substrate` regression).
- **Native AMI boot recipe:** `qemu-img convert -O raw` the `usr.img` FIRST (it is qcow2; a dd of qcow2 has no MBR -> no boot), bake the boot cmdline at disk offset 512 (native EC2 has no QEMU `-append`), `register-image --boot-mode legacy-bios --ena-support`, seed pgdata via cpiod -> dd -> a 2nd EBS attached to the STOPPED instance.

## The procedure

1. **Pick the substrate + hold it identical.**
   - Native (preferred, deployment-truth): both OSes on the same instance type (e.g. `m5d.4xlarge`, local NVMe, ENA). Build the OSv-native AMI with the current fix stack (PULL wake fix + W2 + ENA); Linux = Ubuntu 24.04 AMI.
   - QEMU (reliable harness, when native is blocked): both guests on the same `m5d.metal` host, identical qemu, single-queue vhost tap, local-NVMe data path (no EBS in the data path).

2. **Match storage.** Both on OpenZFS. Pick ONE config and apply it to BOTH: e.g. `ashift=12, recordsize=8K` (PG's 8K page), `compression=off, atime=off, sync=standard`, same pool topology on the same local NVMe. **Prove it:** `zfs get recordsize,ashift,compression,atime,sync,logbias pgdata` on BOTH, confirm identical, and paste it in the result. That paste IS the apples-to-apples evidence.

3. **Match PG + workload.** Same `postgres` args both. `pgbench -i -s<N>` (light `-s50` reproduces the concurrency cliff; the collapse is fault/dispatch-driven, not dataset-size-driven). Sweep `c1/8/16/32/48/64`. `>= 2 rounds/cell`, discard a warmup, report the stable value.

4. **Drive over the real network** from a 3rd same-SG instance. `pgbench -h <guest-real-ip>` (ENA IP native, or tap IP in QEMU), NEVER loopback.

5. **Gate on 0-failed.** Any cell with failed transactions is discarded, not reported. (A crash/livelock is a stability bug in the thing under test, not a throughput number.)

6. **Report a matched table + per-cell ratio,** both RO (`pgbench -S`) and RW (TPC-B default). Label any leg that isn't apples-to-apples (e.g. an MQ leg) separately. State host idle% at the collapse point (idle => a scaling/dispatch bottleneck; saturated => a real CPU/constant-factor limit).

## Known-good parity baseline (regenerate, do not trust stale)

The trustworthy matched numbers as of this project's PULL wake fix (PR #1472), W2-clean base, QEMU single-queue:
- RO OSv/Linux: c1 ~1.1x, c8 ~0.82x, c16 ~0.71x, c32 ~0.51x, c48 ~0.51x, c64 ~0.15x (mid-range cliff closed by PULL; extreme tail is the open lever).
- RW earlier numbers (OSv-ZFS vs Linux-ext4) were CONFLATED; a native ZFS-vs-ZFS RW run is the one to trust. Re-run per this skill.

## AWS substrate

Generic launch/tune/terminate is in the `aws-benchmark` skill; PG-on-NUMA specifics in `pg-numa-benchmark`. This skill is the *fairness layer* on top. Whatever account is current (accounts rotate; check the current profile), use local-NVMe instances (no EBS in the data path), tag every instance+volume, and **terminate instances + delete volumes + deregister AMIs + delete snapshots at the end** — the native AMI flow creates many scratch EBS volumes that orphan silently (this project once leaked ~3.9TB that way). Print artifact-ids continuously and confirm each deleted.

## Durable sources

Code fixes live on `gh-fork` (github.com/gburd/osv-1) branches; the diagnostic writeups + ROADMAP are on the `session-state-*` branch there (the working `.local/` is host-local and does not survive host changes — push anything durable). Rebuild OSv from source per the current fix branch rather than copying AMIs cross-account.
