# Tail latency: the picture after three causes (MAJOR REVISION)

2026-09-07. The gate re-test (agent f18ef8dd) substantially revised the diagnosis.
Read this instead of the earlier two-causes note where they conflict.

## The guest-global freeze IS FIXED

On base 73a332f26 (virtio-blk fix + fault-path fix), an ESTABLISHED persistent
session now measures:

    median 1.9 ms | p99 69.7 ms | max 529 ms | samples >=5s: ZERO

The earlier phenomenon - all 32 backends frozen in lockstep, qemu CPU at
2200-2600%, disk idle, 31 backends on LWLock:WALWrite - is GONE. Fixes 1 and 2 did
remove it. That is a real, measured win:

| base | worst stall | NOPM |
|---|---|---|
| neither fix | ~19,300 ms | - |
| + ae077860c (virtio-blk completion) | ~7,800 ms | 102,026 |
| + dad77b7f/746e5bcd (fault-side AS lock) | 11,690 ms (fresh-connect only) | 152,323 (+49%) |

## But the GATE still FAILS - because it measures something else

Gate: baseline A, VU32, probe only. n=278, median 191.2 ms, p99 6782.7 ms, max
11,690 ms, **12 samples >=5s** (required 0). NOPM 152,323, so it ran at full speed -
not observer-throttled.

The gate probe opens a FRESH psql per sample, so it measures the **fork/connect
path**, not steady-state query latency. Same guest, same window:

| probe | median | p99 | max | >=5s |
|---|---|---|---|---|
| persistent session | 1.9 ms | 69.7 ms | 529 ms | 0 |
| fresh connect (gate) | 207.9 ms | 6592 ms | 7226 ms | 10 |

## Third cause: fork serializes guest-wide at ~150 ms/fork

On an IDLE guest (no HammerDB, no writes):

    K=1   wall= 156.4ms   per_conn=156.4ms
    K=2   wall= 430.8ms   per_conn=215.4ms
    K=4   wall= 582.1ms   per_conn=145.5ms
    K=8   wall=1144.5ms   per_conn=143.1ms
    K=16  wall=2434.0ms   per_conn=152.1ms
    K=32  wall=4743.1ms   per_conn=148.2ms      <-- ZERO parallelism

Controls isolating it to fork: 32x `psql --version` (no connect) = 10.6 ms; one
session doing 32 queries = 154 ms; 32 bare connect+disconnect = 4715 ms. Guest-wide
fork throughput is capped at ~6.7/sec.

**The decisive discriminator** - cost scales with vCPU COUNT, not with resident set:

| guest | single connect | 32 concurrent |
|---|---|---|
| -smp 2 | 71.8 ms | 2081 ms |
| -smp 8 | 88.2 ms | 2538 ms |
| -smp 32 | 142.7 ms | 4349 ms |

Touching 0 / 512 / 2048 / 6000 MB of shared_buffers left fork cost flat at ~150 ms.
Cost rising with CPU count on an IDLE guest can only be a cross-CPU broadcast. No
ZFS/WAL/ARC mechanism produces that.

**The code path:** `fork()` -> `mmu::clone_address_space()` (core/mmu.cc ~618) holds
`parent->vmas_mutex->for_write()` across the whole recursive write-protect walk
(`clone_pt_level<2>`..level 0), releases it, then calls `mmu::flush_tlb_all()`
(~line 704). That takes the single file-scope global `tlb_flush_mutex`
(arch/x64/mmu.cc:61) with one global `tlb_flush_waiter`, IPIs all other CPUs, and
`wait_until()`s every confirmation. Note the flush was deliberately moved OUTSIDE
the mutex to avoid a self-deadlock (COW fault -> vm_fault -> vmas_mutex for_write,
already held) - any fix must respect that ordering.

**Why the gate saw a ramp, not a freeze:** probe latency climbed smoothly
3549->4930->5192->...->6993 ms over ~70 s with sample gaps widening 1.2s->7.5s,
ending in 33x `FATAL: sorry, too many clients already`. That is a queue growing at a
fixed service rate (~6.7 forks/s), not stop-the-world. The two >=10 s outliers land
exactly at the VU-32 connect storm at run start: 32 serialized forks ~= 4.8 s floor
plus the probe queued behind it ~= 10-11 s. Quantitatively consistent.

## My earlier suspects were WRONG - explicitly ruled out

I had pointed at the ZIL commit path, ARC eviction, and the page allocator under the
WALWrite lock. During captured stalls on this base: PG waits were `Client/ClientRead`
(idle) only, **no LWLock:WALWrite at all**; qemu CPU ~590% (not 2200%); disk idle.
Host perf: 90.9% in `kvm_cpu_exec`/`kvm_vcpu_ioctl`, `vmx_vcpu_run` 5.0%,
`vmx_vmexit` 4.3%, `clear_page_erms` 1.6% (fork page zeroing) - VM-exit-heavy,
consistent with IPI traffic.

Agent's own stated limits, which I respect: host perf cannot resolve guest symbols
(corroborates, does not prove), and the pgwaits capture lagged the stall by ~50 s, so
treat the ClientRead snapshot as near-stall. The idle-guest fork scaling data
(lag-free) carries the argument.

## Fix direction (agent 5052cc0d retargeted to this)

At fork time, determine which of the two needs a broadcast:
- the PARENT's newly write-protected PTEs DO need publishing to CPUs running the
  parent's other threads - likely genuinely necessary;
- the CHILD's PTEs are not reachable from any CPU yet (nothing scheduled in the
  child AS), so flush work on the child's behalf is unnecessary.
Candidates, preferred order: (a) narrow the broadcast to CPUs that could be running
threads of the PARENT address space - check whether the existing
`is_app()`/`app_thread`/`lazy_flush_tlb` filtering in `flush_tlb_all` already
approximates this and can be made per-AS; (b) remove the guest-global serialization -
the single `tlb_flush_mutex` + single `tlb_flush_waiter` forbid two broadcasts being
in flight, which is exactly what the vCPU-count scaling implicates.

Iterate on the fork microbenchmark (K concurrent connects, K=1..32 on an idle guest),
not the full gate - success looks like sub-linear scaling. Only then run the gate.

## Deviation on record

Static IP instead of DHCP (the guest blocks forever on DHCPDISCOVER, no DHCP server
on br0). Ruled out as a cause four ways: the persistent session over the same TCP
path is 1.9 ms median; idle-guest connect cost scales SMOOTHLY with vCPU count
whereas DHCP/ARP retries are fixed 1/2/4 s steps; a static IP has no renewal at all;
and 32 host `psql --version` = 10.6 ms rules out host-side cost. The final
ICMP/raw-TCP confirmation was lost when the box went down - flagged, not papered over.

## Note

A previous box was terminated mid-run by an EXTERNAL actor ("User initiated", not the
agent). Agents must push work as they go rather than trusting the box to survive.
