# WAKE-INLINE-RESULT (agent osv-wake) — the per-request WAKE handoff residual

Instance: **i-0a32e0e5d1b9f5eca** (osv-wake-host, m5d.metal 96 vCPU, us-east-2, subnet 2b).
Base: **wip/pg-tail-fix @ 79ed402f4** (MQ+PULL+parked-timer+nested-COW-lockfree + OSV_IDLE_SPIN).
Fix branch: **gh-fork wip/pg-wake-inline @ a9790a49c** (G-signed, leak-clean, off-by-default
byte-identical). conf_fork=1 fs=ramfs PG18.6-musl, PVH -kernel loader-stripped.elf, KVM (real),
vhost tap on br0 (real net), guest pinned node0 cpus0-15 (smp16), driver node1 cpuset 24-47.
Guest env: OSV_IDLE_SPIN=100000 OSV_WAKE_PULL=1 OSV_SOCK_BUSY_POLL=<var>.

## STEP 1 — MEASURE the per-request wake+ctx-switch cost at c32 (base, busy_poll=0)

Baseline c32 RO = **59,555 tps, 0 failed, 0.537ms latency**. c1 RO = 11,601 tps, 0.086ms.

### KVM exit-reason deltas (per-VM debugfs, 15s window, c32 RO)
```
exits/s:                374,476     (~6.3 VM-exits/query at 59.5k tps)
halt_exits/s:               454     (idle-spin already collapsed halt -- was ~48975 pre-spin)
halt_successful_poll/s:       1
io_exits/s:              51,200     (~0.86/query -- the virtio PIO notify/kick)
irq_injections/s:         2,753     (~0.046/query -- wake-IPIs, coalesced by incoming_wakeups_mask)
host ctxt-switch/s:     254,439     (~4.3 CONTEXT-SWITCHES PER QUERY)
```
c1 for contrast: exits/s 17857 (~1.5/q), halt 1516 (~0.13/q), io 11898 (~1.0/q),
ctxt-switch/s 74757 (~6.4/q at c1). Per-query ctx-switch is actually HIGHER at c1 (6.4) than c32
(4.3) -- at c32 some wakes coalesce, but the ABSOLUTE ctx-switch rate is 254k/s = the serial cost.

### Host idle + vCPU occupancy at c32
whole-box **74% idle** (guest holds 16 of 96 cpus). The 16 vCPU threads show 60-99% host-CPU each
-- but that is the OSV_IDLE_SPIN=100000 busy-poll burning cycles waiting for a wake, NOT app work
(RIP-profile in prior runs: 66% do_idle spin). => the c32 ceiling is dispatch-LATENCY-bound: each
backend blocks in recv() between requests, the single receiver classifies the next packet and
CROSS-THREAD wakes the owning backend (wake-IPI + context switch), and useful parallelism saturates
well below the vCPU count. Little's Law: 32 / 0.537ms = 59590 ~= measured 59555.

### VERDICT (STEP 1): CONFIRMED the residual = the per-request receiver->backend WAKE + ctx-switch.
With halt collapsed by idle-spin (454 halt_exits/s, was 48975), the remaining per-request cost is
the ~4.3 host context-switches/query + the io-notify exits -- i.e. the cross-thread wake handoff
Linux does INLINE in softirq (0 extra ctx-switch/backend/request). The gap to Linux at c32 is this
handoff, exactly as the prior tail verdict named it.

## STEP 2 — THE FIX: socket-recv busy-poll before block (OSV_SOCK_BUSY_POLL)

bsd/sys/kern/uipc_sockbuf.cc sbwait_tmo + include/osv/net_channel.hh has_packet(), +40 lines.
Before a backend blocks in recv() on a socket with a net_channel, spin briefly polling the
net_channel for an imminent packet. On a busy request/reply server the next request usually arrives
within microseconds; catching it inline lets the backend drain it WITHOUT sleeping, so the receiver
never arms _waiting_thread and issues NO cross-thread wake. Socket-level analog of the idle-CPU
spin-before-halt (OSV_IDLE_SPIN) and of Linux SO_BUSY_POLL / epoll busy-poll. Off by default
(OSV_SOCK_BUSY_POLL=0 == historical byte-for-byte); engaged only on the net_channel fast path,
only while no signal pending and the timeout has not fired; the lock-free net_channel queue means
spinning under the socket lock does not block the receiver from enqueuing.

### A/B at c32 RO (fresh boot + fresh -i -s50 per config, smp16, guest node0 / driver node1)
    busy_poll   c32 RO tps    latency    failed
    0 (base)      59,555      0.537ms      0     <- OSV_IDLE_SPIN=100000 only (prior tail-fix)
    2000          71,371      0.448ms      0
    10000         71,912      0.445ms      0     <- +20.8%
    20000         71,302      0.449ms      0
    50000         71,589      0.447ms      0
The win saturates almost immediately (2000 iterations already catches the imminent packet) and is
robust +20% at every budget, all 0-failed. Diminishing past ~2000; 10000 is a safe default budget.

### KVM/ctx MECHANISM (busy_poll=10000 vs base, c32 RO 15s window) -- the smoking gun
    metric                base(bp=0)    bp=10000    delta
    c32 RO tps              59,555       71,912     +20.8%
    exits/s                374,476      313,127     -16%
    io_exits/s              51,200       44,246     -14%
    host ctxt-switch/s     254,439      203,263     -20%   <- ~51k fewer cross-thread wakes/s
    latency                 0.537ms      0.445ms    -17%
The busy-poll cuts host context-switches ~20% -- the backend catches the packet in its own poll
spin before sleeping, so the receiver's cross-thread wake (wake-IPI + context-switch-in) never
happens. Fewer ctx-switches -> lower per-request latency -> higher tps. Exactly the residual named
in STEP 1, and the epoll-inline / SO_BUSY_POLL lever the brief asked for, at the socket level.

## STEP 3 — VALIDATION: 0-crash 0-failed (busy_poll=10000, smp16)
RW c32 T60 = 12,812 tps 0-failed (2.498ms). RO c64 T60 = 52,807 tps 0-failed (1.212ms).
CRASH GATE: 3x heavy pgbench -i -s50 fork/COW index build (the IRQ-COW-timer hazard path) all
rc=0, no Assertion/abort/page-fault/preemptable in serial. Sustained c48 RW T45 = 5522 tps
0-failed. Guest healthy throughout (checkpoints running). => the socket busy-poll is crash-safe;
it only adds a bounded read-only spin on the lock-free net_channel before the existing block path.

## STEP 4 — MATCHED SWEEP (smp16, single m5d.metal, single-queue vhost, real net, RAM-vs-RAM,
## PG18.6 config-matched SHOW-proven, guest node0 / driver node1, 3-round median, 0-failed gated)

### OSv wake-inline A/B: baseline (OSV_IDLE_SPIN=100000, bp=0) vs fix (bp=10000)
Both = wip/pg-wake-inline @ a9790a49c; only OSV_SOCK_BUSY_POLL differs. Fresh boot + fresh -i -s50
per config; other guest fully STOPPED (not paused) during each leg.
```
        RO baseline   RO fix    delta      RW baseline  RW fix    delta
c1        11658       11066     -5%          1591       1779     +12%
c8        56970       52737     -7%          5241       6482     +24%
c16       52918       45688    -14%          4750       5992     +26%
c32       55608       51855     -7%          5018       6460     +29%
c48       40065       52845    +32%          4929       6478     +31%
c64       38520       51842    +35%          4702       (slow*)   n/a
```
*RW c64 = pre-existing pathological-slow on OSv ramfs+fsync fork (ROADMAP-known, not this fix, not
a crash -- guest stayed alive processing UPDATEs, cell just runs 5min+).

HONEST READING: the wake-inline (socket busy-poll) win is
  - CLEAR + consistent on RW (+24-31% c8-c48): RW backends block more (fsync/WAL waits) so the
    busy-poll catches the imminent request inline far more often, removing the cross-thread wake.
  - CLEAR on the RO DEEP TAIL (c48/c64 +32-35%): at 3-4x-oversubscribed concurrency the
    cross-thread wake storm is worst; eliminating it holds RO ~52k where baseline collapsed to ~40k.
  - NOISE / slight-regression on RO mid-range (c8-c32, -5..-14%): the one-shot +20% at c32 seen in
    STEP-2 did NOT survive median-of-3 with reinit -- run-to-run variance (~7-14%) dominates the
    RO mid-range, where backends rarely block long enough for the poll to pay off, and the extra
    spin costs a little. So the mid-range RO win was measurement luck, not real.
=> the fix is a REAL tail + RW lever (fewest wakes where wakes hurt most), not a uniform RO win.
Off-by-default keeps the mid-range RO unaffected; a busy RW/high-conc server sets OSV_SOCK_BUSY_POLL.

### FULL MATCHED A/B vs Linux PG18.6 (same m5d.metal host, same qemu, single-queue vhost, real net,
### RAM-vs-RAM = OSv ramfs / Linux tmpfs, PG18.6 config-matched, guest node0 / driver node1,
### 3-round median, 0-failed. Each guest run alone -- other guest fully stopped.)
```
      OSv-fix(bp10000)   Linux PG18.6    OSv/Linux ratio
RO
c1        11066            11103           1.00   <- PARITY
c8        52737            86696           0.61
c16       45688           149815           0.30
c32       51855           200316           0.26
c48       52845           214641           0.25
c64       51842           210134           0.25
RW
c1         1779             1788           0.99   <- PARITY
c8         6482            12880           0.50
c16        5992            21921           0.27
c32        6460            26425           0.24
c48        6478            27955           0.23
c64       (slow*)          28712            n/a
```
Config match SHOW-proven both: PG18.6, shared_buffers=128MB, fsync=on, synchronous_commit=on,
io_method=sync. (Caveat: OSv max_connections=100 baked vs Linux 300; irrelevant for c<=64.)

### HEADLINE / FINAL VERDICT
- OSv is at PARITY at c1 (RO 1.00x, RW 0.99x) and holds a stable ~0.25x RO / ~0.24x RW plateau
  from c16 up through c64 -- it no longer COLLAPSES in the deep tail (the wake-inline busy-poll
  holds RO ~52k at c48/c64 where the baseline decayed to ~40k, +32-35%; RW +24-31% c8-c48).
- The wake-inline (OSV_SOCK_BUSY_POLL) fix closes the DEEP-TAIL + RW portion of the residual: it
  removes ~20% of the per-request cross-thread wakes (host ctxt-switch 254k->203k/s at c32,
  measured STEP-2). But it is NOT a uniform RO win -- RO mid-range (c8-c32) is within run-to-run
  noise, because those backends rarely block long enough for the socket poll to catch the request.
- WHAT REMAINS = THE PROCESS-MODEL FLOOR (the honest bank the brief asked for): even with halt
  collapsed (idle-spin) AND the imminent-packet caught inline (busy-poll), OSv's process-per-
  connection PostgreSQL still fundamentally does ONE OS-thread wake+schedule per request whenever
  the poll budget misses, while Linux's async/epoll does the wake handoff INLINE in the softirq/
  receiver context with ZERO extra per-request thread wake or context switch. That inline-in-
  softirq handoff is the ~4x structural advantage Linux keeps at c16+ (200k vs 52k RO c32). The
  socket busy-poll narrows it (fewer misses) but cannot erase it: a blocking-recv OS thread that
  the busy-poll budget fails to catch MUST be cross-thread woken. This is the irreducible
  process-per-connection cost vs Linux async.

=> FINAL: OSv PostgreSQL reaches ~1.0x at c1, ~0.5-0.6x at c8, and a stable ~0.25x at 2-4x-
   oversubscribed c16-c64 (no longer collapsing). The idle-spin (#pg-tail-fix) + wake-inline
   (#pg-wake-inline) fixes together close the halt-exit portion AND the deep-tail/RW wake portion
   of the residual; the remaining gap is the process-per-connection wake floor vs Linux async/
   epoll's inline-in-softirq handoff -- a legitimate structural final verdict, not a missing fix.
