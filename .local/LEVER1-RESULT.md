# LEVER 1 — de-serialize the single virtio-net receiver() RX dispatch — RESULT (incremental)

## Instance
- instance-id: **i-024e02d6ddd956498** (m5d.metal, us-east-2, real bare-metal KVM, acct 840154381708/beef)
- public IP: 18.222.223.115
- Base: OSv gh-fork integ/pg-fork-zfs tip **dad77b7fa** (= 6b71c76385 + 746e5bcd9 RCU-registry L1 + dad77b7fa COW-peek L2), image=zfs-tools,pg18-fork fs=zfs conf_zfs=openzfs conf_fork=1, DEFAULT mmap.

## Lever 1 design (Option A)
- receiver() still classifies + push()es (SPSC-safe: it stays the SOLE producer to each net_channel ring),
  but DEFERS the wake() calls. During a drain pass it collects the DISTINCT net_channels touched, then hands
  the wake fan-out to per-CPU wake-worker threads so the wake + cross-CPU IPI + woken-backend scheduling do not
  serialize on the receiver's CPU. Receiver returns to draining immediately.
- Toggle: env OSV_NET_DISPATCH_FANOUT=1 (off = stock inline classify+wake).
- Generic (no PG-awareness). Pure net/sched -> STANDALONE MASTER PR candidate if it lifts RO.

## BASELINE RO sweep (FANOUT=0, over tap0 192.168.100.2, NOT loopback, 0 failed, DUR=25 -s50)
| cN  | tps    | lat_ms |
|-----|--------|--------|
| c1  | 12587  | 0.079  |
| c8  | 85538  | 0.094  | <- PEAK
| c16 | 28030  | 0.571  |
| c32 | 20353  | 1.572  | <- COLLAPSE
| c48 | 24212  | 1.983  |
| c64 | 24786  | 2.582  |
Collapse reproduced: c8 peak -> c16/c32 drop, latency climbs 0.094->2.58ms. Matches WAKE-LATENCY signature.
Working PGARGS: PG-default shared/dynamic memory + io_method=sync (sysv broke DSM). bench DB = postgres (locale C; OSv lacks C.UTF-8).

## STATUS: baseline banked; running WAKEPROF c32 + FANOUT=1 fixed sweep next.

## OPTION A RESULT (OSV_NET_DISPATCH_FANOUT=1: receiver defers wake -> per-CPU wake workers) = NULL / slightly WORSE
### Fixed RO sweep (FANOUT=1) vs baseline
| cN  | base tps | A tps  | delta   |
|-----|----------|--------|---------|
| c1  | 12587    | 5409   | -57%    |
| c8  | 85538    | 72581  | -15%    |
| c16 | 28030    | 31560  | +12.6%  |
| c32 | 20353    | 21243  | +4.4%   |
| c48 | 24212    | 20486  | -15.4%  |
| c64 | 24786    | 18716  | -24.5%  |
No flatten. c16/c32 barely move; c1/c48/c64 REGRESS.

### WAKEPROF c32 (the tell): pile-up did NOT drop, it grew
| metric            | baseline | Option A |
|-------------------|----------|----------|
| rq>=5 %           | 5.61%    | 7.42%    | (WORSE)
| rq>=3 %           | 23.08%   | 21.29%   | (~flat)
| wake->run avg     | 25.5us   | 36.3us   | (WORSE)
| IPI wakes         | 676k     | 1176k    | (nearly DOUBLED)
| local wakes       | 1013k    | 836k     | (dropped)

WHY A FAILS: offloading the wake CONVERTS cheap same-CPU local wakes into
cross-CPU IPIs (receiver -> IPI to worker -> worker issues IPI to backend =
MORE IPIs + an extra hop), adding latency instead of removing a serial point.
The wake ISSUE was not the serial bottleneck; the extra fan-out layer hurts.

## STATUS: Option A NULL. Trying Option B (per-CPU dispatch shards: classify+push+wake on the OWNING CPU by conn hash).

## OPTION B RESULT (OSV_NET_DISPATCH_SHARD=1: receiver hashes 4-tuple -> owning per-CPU shard does classify+push+wake) = NULL
### Fixed RO sweep (SHARD=1) vs baseline
| cN  | base tps | B tps  | delta   |
|-----|----------|--------|---------|
| c1  | 12587    | 10150  | -19%    |
| c8  | 85538    | 80868  | -5.5%   |
| c16 | 28030    | 30529  | +8.9%   |
| c32 | 20353    | 22411  | +10.1%  |
| c48 | 24212    | 17759  | -26.6%  |
| c64 | 24786    | 18429  | -25.6%  |
Still no flatten. c16/c32 +9-10% but c48/c64 REGRESS -26%.

### WAKEPROF c32
| metric        | baseline | Option A | Option B |
|---------------|----------|----------|----------|
| rq>=5 %       | 5.61%    | 7.42%    | 5.96%    |
| rq>=3 %       | 23.08%   | 21.29%   | 18.51%   | (B lower)
| mean depth    | 1.90     | 1.92     | 1.80     | (B lower)
| wake->run avg | 25.5us   | 36.3us   | 29.2us   | (both WORSE)
| IPI wakes     | 676k     | 1176k    | 1201k    | (both ~2x)
| local wakes   | 1013k    | 836k     | 904k     |

B nudges mid-depth pile-up down (rq>=3 23->18.5%) but roughly DOUBLES IPIs and
RAISES wake->run latency, so throughput does not lift.

## VERDICT: LEVER 1 (dispatch fan-out, both A and B) = NULL. Collapse does NOT flatten.
Both options move the wake/dispatch to another CPU, which CONVERTS cheap
same-CPU local wakes into cross-CPU IPIs (~2x the IPIs) plus an extra thread
hop.  The dispatch (classify+push+wake) is cheap enough that shipping it across
a CPU boundary costs MORE (IPI + hop latency) than the serialization it removes.
The runqueue pile-up barely moves because the limiter is the per-query
ROUND-TRIP through the single RX + single TX + wake path, not the location of
the wake call.  On this single-hw-queue tap NIC, parallelizing the DISPATCH is
IPI-bound and does not convert idle CPUs into throughput.

WHERE THE PILE-UP WENT: it stayed (rq>=5 ~5-7% in all three).  The added
per-request latency is dominated by the IPI + wake-placement round-trip
(lever 2 territory: WHERE the woken backend lands), not by the receiver
issuing the wakes serially.  The profile's "serial dispatch stage" is real but
is not relieved by fanning the wake/classify across CPUs - the cross-CPU cost
cancels the parallelism for a cheap ping-pong dispatch.

## Branch pr/net-rx-dispatch-fanout (gh-fork): base dad77b7fa + Option A + WAKEPROF + Option B.
Both options env-toggled, off by default, conf_fork-neutral net/sched.  NOT
opened as a PR (null result).  RW sweep skipped (RO already null; the mechanism
is the same for RW).

## RW no-regression (DEFAULT path, both toggles OFF = stock inline path)
| cN  | rw tps | lat_ms | failed |
|-----|--------|--------|--------|
| c8  | 5277   | 1.516  | 0      |
| c32 | 10126  | 3.160  | 0      |
Default path serves RW normally (the change is entirely behind `if (enabled())`
guards, so the default build is byte-for-byte the stock dispatch path).

## CONCLUSION
Lever 1 as specified (fan out the RX DISPATCH across CPUs) is a NULL: on a
single-hardware-RX-queue tap NIC, both offloading just the wake (A) and
sharding the full classify+wake (B) trade the receiver's serial wakes for
cross-CPU IPIs at ~2x the IPI count, adding round-trip latency instead of
converting idle CPUs into throughput.  The collapse does NOT flatten toward
Linux (130-159k); c16/c32 move +/-10%, c48/c64 regress.  The remaining
per-request cost is a per-query ROUND-TRIP + wake-PLACEMENT effect (lever 2:
where the woken backend lands), not the receiver issuing wakes serially.
Next lever to try (was deferred): light wake-placement / idle-CPU steering
(lever 2), now that lever 1 is measured null - the IPI-bound round-trip is
where the time is.

## CLEANUP
instance i-024e02d6ddd956498 TERMINATED (terminate accepted -> shutting-down;
root vol DeleteOnTermination=true, local NVMe ephemeral); qemu reaped (0);
docker containers removed (0); no other metal instance of mine running. The 2
"available" EBS volumes in the account are NOT mine (untagged, predate/differ
from my 120G root; solnix leftovers, left alone per directive).
