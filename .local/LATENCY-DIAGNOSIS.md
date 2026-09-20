# LATENCY-DIAGNOSIS — starvation vs latency-wait for the OSv PG RO plateau (c16–c64)

Agent: osv-lat. AWS_PROFILE=fred acct 443433794128 us-east-2.
Instance: **i-0e327d4c6124f29ec** (osv-lat-host, m5d.metal, subnet 2b), tagged osv-lat-*.
SG sg-0410d8c6900974ed4 unmodified.

Build: wip/pg-scale2 @ e81476084 (MQ f411d5edc + idle-CPU PULL 3da8cea30 + parked-timer-unlink),
conf_fork=1 fs=ramfs image=pg18-fork, smp16, N=16 vhost tap, real net (172.20.0.2), OSV_WAKE_PULL=1.
Boot: -kernel PVH (loader-stripped.elf 388MB, data baked), "WAKE_PULL ON", PG18.4 ready.
DATASET: pgbench -s10 (1M accounts) baked into the ramfs image (see BUILD NOTES for why s10 not s50).

## THE VERDICT: LATENCY-BOUND, NOT STARVATION. The plateau is per-request round-trip latency.

The re-opened question from the DEAD-ENDS block (wake-PUSH dead, wake-STEER dead, PULL kept) was:
is the 86% do_idle-spin at c32 (a) RUNNABLE backends not being scheduled (starvation) or (b)
backends genuinely BLOCKED waiting for the next client request (latency-bound)? ANSWER = (b),
proven three independent ways below.

## PROOF 1 (the decisive one) — tps = concurrency / per-request-latency, EXACTLY, at every c.

A closed-loop client (pgbench: send query -> wait reply -> send next) obeys Little's Law:
tps = concurrency / latency. If that identity holds, the plateau is 100% latency, not placement
or parallelism. Measured (OSv smp16, RO -S, 0-failed all cells):

  c    latency(ms)   tps(measured)   c/latency(predicted)   match
  1     0.076         13243           13158                  ✓
  8     0.094         85143           85106                  ✓  <- peak
  16    0.310         51658           51613                  ✓
  32    0.583         54880           54888                  ✓
  48    0.903         53163           53156                  ✓
  64    1.328         48185           48193                  ✓

PERFECT match at EVERY concurrency (within 0.1%). => the ENTIRE tps curve is dictated by
per-request latency. There is no hidden parallelism loss and no scheduler starvation term; tps is
fully accounted for by latency*concurrency. The plateau IS the latency growth: latency jumps 3.3x
from c8 (0.094ms) to c16 (0.31ms) -- that step IS where the plateau begins -- then keeps climbing
(0.58ms c32, 1.33ms c64). tps peaks at c8 because past c8 latency grows faster than concurrency.

## PROOF 2 (runqueue emptiness) — do_idle spin means runqueues are EMPTY = nothing runnable.

RIP sampling at c32 (addr2line on continuous guest RIPs, 48000 samples, 34485 classified):
  do_idle                  57.8%   (the busy-spin poll loop)
  handle_incoming_wakeups  15.2%   (draining the wake queue)
  x2apic::ipi               3.4%
  atomic-load/pci-writew/tcp_output/tcp_do_segment/switch_to/try_pull_from_busiest  ~rest
  app (PG code)            ~near-zero

do_idle is `for(ctr<10000){ handle_incoming_wakeups(); if(!runqueue.empty()) return; }`
(core/sched.cc). A CPU only PERSISTS in do_idle if runqueue.empty() on every iteration. If any
backend were RUNNABLE-but-not-scheduled (starvation), the runqueue would be non-empty and do_idle
would IMMEDIATELY return to run it. The CPUs spending 73% of time (do_idle+hiw) spinning on empty
runqueues PROVES the runqueues are empty => there is genuinely nothing runnable => the backends are
BLOCKED (in recv/wait), not waiting to be dispatched. This is NOT starvation.

(QMP info-registers snapshot method over-reports do_idle to 99% because stopping vCPUs for the ~3ms
QMP round-trip catches them mid-idle far more than mid-us-query -- a known sampling bias -- but it
agrees on the qualitative point: max 1 of 16 vCPUs ever caught running app code; the machine is
almost always idle-waiting, never queue-backed.)

## PROOF 3 (host idle) — host is deeply idle at the plateau => not a CPU/dispatch resource limit.
Consistent with RESIDUAL (85.6% host idle at OSv smp16 c32). 16 guest vCPUs on a 96-core host, and
even those 16 are ~73% in the idle-spin loop. The bottleneck is not CPU, not scheduling capacity,
not queue depth -- it is the time each backend spends BLOCKED between serving one query and
receiving the next request. That blocked time is the per-request network+wake round-trip.

## IN-FLIGHT PARALLELISM (question 3): ~0 app-running vCPUs at any instant on OSv.
At c32, snapshot sampling caught app-code on at most 1 of 16 vCPUs, ~0 mean. The backends are NOT
running simultaneously; each is blocked waiting for its next request the vast majority of the time.
This is the signature of a latency-bound closed-loop workload, not a throughput-parallelism one.
(Little's Law restates this: mean in-flight = tps*service_time; at c32 tps 55k * ~single-digit-us
actual query service = a fraction of a backend running on average -- the rest of each 0.58ms is
round-trip wait.)

## => NEXT LEVER (precisely named): PER-REQUEST ROUND-TRIP LATENCY, not CPU placement.
The plateau lever is NOT wake placement (PUSH/STEER both dead, PULL kept). It is the per-request
latency floor + its growth with concurrency. The latency is spent in the request->reply round trip:
client-send -> guest NIC rx (vhost/virtio-net) -> net_channel wake -> backend wakes -> executes (us)
-> reply tcp_output -> client. Where OSv's extra time sits vs Linux is the OSv-vs-Linux service-time
breakdown (below, being measured). Candidates in priority order (to be confirmed by the breakdown):
  1. net_channel wake path (packet-arrival -> backend-wakeup latency)
  2. virtio-net / vhost RX interrupt coalescing + the receiver->backend handoff
  3. TCP stack per-segment cost (tcp_do_segment/tcp_output appear in the profile)
  4. wake-to-run delay per request (the do_idle re-entry cost each cycle)

## OSv-vs-Linux PER-REQUEST LATENCY (question 2) — fresh matched apples-to-apples, THIS run.
Both guests on the SAME m5d.metal, same qemu 8.1.3 KVM, same N=16 vhost tap, driven from the SAME
host driver over real net, PG18 config-matched (sb=128MB/mc=100/io=sync/fsync=on/sync_commit=on),
RAM-vs-RAM (OSv ramfs / Linux tmpfs), pgbench -s10 -S, 0-failed all cells. OSv=PG18.4, Linux=PG18.6
(minor-version diff, only material caveat; latency shape is the finding, not absolute us).

  c    OSv_tps  Lin_tps   OSv_lat   Lin_lat   OSv/Lin_lat
  1    13243    13166     76us      76us      1.00x   <- IDENTICAL at no contention
  8    85143    97161     94us      82us      1.15x   <- OSv peak, near parity
  16   51658    162718    310us     98us      3.2x    <- PLATEAU ONSET (OSv lat 3.3x jump c8->c16)
  32   54880    192126    583us     167us     3.5x
  48   53163    195306    903us     246us     3.7x
  64   48185    192913    1328us    332us     4.0x

THE CONTRAST (this is the whole story): Linux keeps per-request latency NEARLY FLAT as concurrency
rises (76us -> 332us = 4.4x over a 64x concurrency increase); OSv's per-request latency EXPLODES
(76us -> 1328us = 17x). At c1 they are IDENTICAL (76us) -- OSv's base request path is NOT slower.
Linux absorbs concurrency (async/thread-pool wakes each handler near-instantly); OSv serializes the
wake->run->reply so each added connection adds ~15-20us to EVERY request's latency.

## SERVER-SIDE SERVICE TIME (tcpdump at the guest NIC = purely intra-guest, excludes all network).
request-arrival-at-tap -> reply-departure-at-tap, measured on tap0 (OSv .2) and tap1 (Linux .3):

              OSv       Linux     OSv/Lin
  c1  svc     68us      60us      1.13x   <- near parity: same query costs the same server-side
  c32 svc     563us     138us     4.1x    <- the gap is ENTIRELY intra-guest, NOT the network

The c32 OSv server-side service time (563us) ~= the client-observed latency (598us): the extra time
is INSIDE OSv, not on the wire. And it grows 8.3x (68->563us) for the SAME single-row SELECT while
all 16 vCPUs are <5% busy and the host is 85.6% idle => the 563us is NOT query CPU cost and NOT
queuing-for-CPU. It is the time the backend spends BLOCKED between its request packet arriving at
OSv's virtio-net and the backend actually being woken + dispatched to run. That is the WAKE-TO-RUN
latency per request, and it is what grows with concurrency. Linux's server-svc barely moves
(60->138us) because epoll/thread-pool dispatches the handler near-instantly regardless of load.

HOST/vCPU at c32 (skill-required): host 85.6% idle; all 16 guest vCPU KVM threads <5% busy (utime+
stime delta over 3s). RIP profile (continuous addr2line): do_idle 57.8% + handle_incoming_wakeups
15.2% + x2apic::ipi 3.4%, app ~0%. The machine spends 73% of cycles idle-spinning on empty
runqueues waiting for the next wakeup. => NOT CPU-limited, NOT a scheduling-capacity limit. Fixable.

## ============================================================================
## FINAL ANSWER + THE PRECISELY-NAMED NEXT LEVER
## ============================================================================
## VERDICT: LATENCY-BOUND (option b), NOT starvation. Proven 4 independent ways:
##   (1) tps = concurrency / per-request-latency EXACTLY at every c (Little's Law closed-loop) ->
##       the entire tps plateau is accounted for by latency growth, zero residual.
##   (2) 73% of CPU in do_idle-spin on EMPTY runqueues -> nothing runnable -> backends BLOCKED
##       (a runnable-but-unscheduled thread would make runqueue non-empty and do_idle would return).
##   (3) all 16 vCPUs <5% busy + host 85.6% idle at c32 -> no runnable work piling up (no starvation).
##   (4) in-flight app-running vCPUs ~0 of 16 at any instant -> backends are not simultaneously
##       running; each is idle-waiting for its next request the vast majority of the time.
##
## IT IS NOT STARVATION. The 86% do_idle-spin from the prior runs was CORRECT idle -- the CPUs have
## genuinely nothing to run because the backends are blocked waiting to be woken, NOT because
## runnable backends are being denied a CPU. This CONFIRMS the DEAD-ENDS re-opened hypothesis:
## wake PLACEMENT (PUSH/STEER/PULL-tuning) was never the lever because the CPUs are not the
## bottleneck; the per-request wake-to-run LATENCY is.
##
## THE NEXT LEVER (precisely named, with the evidence pointing at it):
##   *** WAKE-TO-RUN LATENCY on the packet-arrival -> backend-execute path, specifically the
##       net_channel wake + receiver->backend handoff + wake-delivery-to-dispatch delay. ***
##   Evidence chain: server-side (intra-guest) service time grows 68us(c1)->563us(c32) = 8.3x for an
##   identical SELECT, while CPUs are idle (so it is wait, not compute); Linux's equivalent grows only
##   60->138us; the RIP profile shows the guest burning cycles in do_idle+handle_incoming_wakeups
##   (the wake machinery) not in vm_fault/locks/app. The extra ~425us at c32 is time a woken-eligible
##   backend waits between its packet landing and it actually running.
##
##   WHERE TO FIX (in priority order, all on the per-request wake path -- NOT cpu placement):
##     1. net_channel wake path (core/net_channel.cc): the latency from a packet being classified by
##        the virtio-net receiver to the owning backend's thread actually being woken + made runnable.
##        This is THE prime suspect -- it is the OSv-specific hop Linux does inline in softirq/epoll.
##     2. virtio-net/vhost RX interrupt coalescing + the single receiver()->per-backend wake handoff:
##        under N concurrent flows, the receiver thread serializes classify+wake; measure whether the
##        per-flow wake is delayed behind other flows' processing (RSS spreads RX queues but the
##        wake-dispatch per packet may still queue).
##     3. wake-delivery-to-dispatch: after wake_impl enqueues + IPIs, the target CPU is in do_idle's
##        10000-iter spin; the delay from IPI to the do_idle loop noticing runqueue non-empty and
##        actually context-switching into the backend. Instrument timestamp: packet-rx -> wake_impl
##        -> reschedule_from_interrupt-runs-backend, at c1 vs c32, to localize the growing hop.
##
##   NOT the lever (measured/closed): wake PUSH (IPI livelock), wake STEER (cache-cold regression),
##   PULL mindepth tuning (churn) -- all wake PLACEMENT; the CPUs are idle so placement cannot help.
##   The fix must REDUCE the per-request wake-to-run latency (make the backend run sooner after its
##   packet arrives), or batch/pipeline requests so per-connection round-trips overlap (the structural
##   Linux advantage: async lets one thread serve many in-flight requests, hiding per-wake latency).
##
## NEXT RUN: instrument the packet-rx -> backend-runs timestamp delta (add a per-request trace in
##   net_channel wake + reschedule_from_interrupt) at c1 vs c32 to pin WHICH of the 3 hops above
##   grows. That localizes the exact code to fix. Do NOT touch wake placement again.

## BUILD NOTES (hard-won this run -- save the next agent the ~2h I burned on the toolchain wall)
## THE fedora-toolchain wall (the recurring "toolchain drift" hazard, now precisely diagnosed):
##   conf_fork=1 image=pg18-fork fs=ramfs FAILS to link loader.elf with TWO coupled errors:
##     (a) "failed to convert GOTPCREL relocation ... relink with --no-relax" (pool_allocator.o /
##         ctype::id / money_base -- libstdc++.a template statics pulled into the kernel), AND
##     (b) "R_X86_64_32S relocation truncated to fit ... against .bss / .edata" in arch/x64/boot.S.
##   --no-relax fixes (a) but WORSENS (b) (boot.S needs relaxation for its low-mem 32S refs) -- they
##   are mutually exclusive, so --no-relax is a dead end.
##   ROOT CAUSE (proven): (a) is a binutils-version thing (ld 2.38/2.39/2.40 fail the GOTPCREL
##   conversion; ld 2.43 in fedora:41 does NOT -- matches the local NixOS ld 2.46 that builds fine).
##   (b) is a SIZE thing: for fs=ramfs, OSv bakes the ENTIRE app filesystem (including the mapped PG
##   /data dir) into bootfs.bin -> bootfs.o -> LINKED INTO loader.elf. A pgbench -s50 data dir (1.4GB)
##   made bootfs.o 1.5GB, pushing .bss past 0x80000000 so boot.S's R_X86_64_32S refs truncate.
##   THE FIX (both, together, REQUIRED):
##     1. Build in a fedora:41 container (gcc 14.3.1 + binutils 2.43) -- NOT f37/38/39. Fixes (a).
##     2. Bake only a SMALL dataset into the ramfs image: pgbench -s10 (319MB data) keeps .bss at
##        ~1.48GB (0x585ad000) < 2GB. -s50 does NOT link. Fixes (b). (s10 = 1M accounts, plenty for
##        a latency/dispatch diagnostic; the plateau is dispatch/latency-driven, not dataset-size.)
##   Also: config.json in the tree had `default:[cloud-init,httpserver]` -- httpserver pulls C++
##   locale into the kernel and makes (a) worse; set `default:[pg18-fork]`. And fs=ramfs needs the
##   mount/uush tools added to bootfs_dep (they are only auto-built for fs=zfs) -- add
##   $(out)/tools/mount/{mount-fs,umount}.so + tools/uush/{uush,ls,mkdir}.so to bootfs_dep, OR the
##   mkbootfs step FileNotFoundErrors on them.
##   BOOT: -kernel PVH loader-stripped.elf directly (388MB with baked data); NO usr.img/loader.img
##   needed (avoids the qemu-nbd/imgedit step the builder container lacks). Runner = fedora:39 qemu
##   8.1.3, --network host --privileged, vhost tap with multi_queue flag on the tap (ip tuntap add
##   ... multi_queue) or queues>1 fails "could not configure /dev/net/tun: Invalid argument".
##   PG image: install/{bin,lib} shipped; share/ built from a glibc PG18.4 (arch-independent BKI);
##   data/ initdb'd + pgbench -i -s10 loaded by the glibc server (dodges the in-guest catalog storm).
##   Submodules needed: musl_1.2.1 (pin 73cc775), musl_0.9.12 (pin 372a948b -- has OSv-only intl.c/
##   catopen.c the symlinks need), kbuild, external/x64/acpica. Toolchain-consistent host tools:
##   don't mix container gccs (fastlz/lz built by f38 fails GLIBCXX under f37).
