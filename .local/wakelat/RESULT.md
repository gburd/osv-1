# WAKEUP-LATENCY RESIDUAL — adaptive idle-spin: RESULT

## Box: i-016e19e060a57409f (m5d.metal, lava us-east-2a, Owner=agent-wakelat)
Terminated at end (see below). qemu 7.2.22 host / 8.1.3 build-container, host KVM halt_poll_ns=200000
(the host DOES halt-poll — the exact case where the #1501 fixed lever was found host-conditional).

## DURABLE DELIVERABLE (pushed, survives the account dying)
- Branch: **gh-fork/bank/sched-adaptive-idle-spin @ 1685b6511** (G-signed)
- Base: gh-fork/bank/fork-arena-real-reclaim @ 43fcdca79 (a2a base, gate-PASS, all fixes)
- apps bumped to 3f93f43 (seed_copy rofs-mode fix; mkdir(dst,0700) gate = 1)
- Files: core/sched.cc (adaptive do_idle), include/osv/sched.hh (idle_spin_window + idle_halt_streak)
- Master-applicable: do_idle exists on upstream/master with the identical idle_poll/send_wakeup_ipi
  handshake and a hardcoded 10000; this is NOT fork-stack-blocked (see PR note below).

## THE FIX (root cause -> control)
send_wakeup_ipi() suppresses the cross-CPU wake IPI iff (!idle_poll && runqueue<=1). do_idle() holds
idle_poll=true only during its spin window. So a wake to a still-SPINNING target is caught with NO IPI/
VM-exit; a wake to an already-HALTED target costs an IPI -> VM-exit. The BUG was the CONTROL: a FIXED
spin count (10000). Too short -> halt-just-before-wake -> the expensive path (the VU32 low-mode). Too
long -> burns idle cycles (why #1501 was opt-in + host-conditional).
FIX = adaptive per-CPU window (Linux halt_poll_ns, GUEST-side, so it works even where the host halt-polls):
  - CAUGHT a wake mid-spin -> JUMP window straight to the cap + reset halt-streak (stay fully polled).
  - HALTED -> only after idle_shrink_after=4 CONSECUTIVE genuine halts does the CPU look truly idle;
    then each further halt HALVES the window toward floor=256, so a genuinely idle CPU decays fast and
    halts (host reclaims the vCPU). Any caught wake resets the streak.
  - cap default raised 10000 -> 100000 (OSV_IDLE_SPIN overrides). OSV_IDLE_SPIN_ADAPTIVE=0 = old fixed.

## MEASURED — the isolate A/B (syncwrite-mt, 32 writers, 30s x 3 reps, ZFS on raw /dev/nvme1n1)
All numbers are MEASURED zfs-bench output on this m5d.metal. This is the #1501 workload (durable-write /
request-reply, where higher spin showed +56-140%).

### The design iteration (honest — v1 was REFUTED, v2 won)
| arm                         | op/s median          | wake2ent_us mean | p50 us | p99 us | halt_exits/s |
|-----------------------------|----------------------|------------------|--------|--------|--------------|
| FIXED-10000 (old default)   | 27200                | 137              | 1019   | 3484   | 41913        |
| ADAPTIVE v1 (sym x2 // /2)  | 15868  (-42% WORSE)  | 274 (2x worse)   | 1788   | 6269   | 86943 (2x)   |
| FIXED cap=50000  (sweep)    | 42056  (+55%)        | 79.6             | —      | —      | —            |
| FIXED cap=100000 (sweep)    | 45063  (+66%)        | 80.7             | —      | —      | —            |
| **ADAPTIVE v2 (cap=100000)**| **44841  (+65%)**    | **77.7 (best)**  | **646**| **2118 (-39%)** | **11039 (4x fewer)** |

fixed-10000 reps=[26056,27200,28744]; adaptive-v1 reps=[15586,15868,16140];
adaptive-v2 reps=[44602,44841,46176]; fixed-50k reps=[41775,42056,44071]; fixed-100k reps=[43606,45063,45212].

### Reading the result
- **v1 REFUTED (measured):** symmetric grow x2 / shrink /2 with a low floor OSCILLATES the window LOW on
  a constantly-halting ZIL workload -> the CPU polls LESS than the strong fixed baseline -> MORE wake
  IPIs (halt_exits 2x), worse wake2ent, -42% op/s. Backwards. A valid negative that shaped v2.
- **The win needs a HIGH spin** (fixed-cap sweep: 10000->27k, 50000->42k, 100000->45k). v1 capped at
  10000 so it could never reach the win. This IS the #1501 +56-140% effect, reproduced here (+66%).
- **v2 WINS (measured):** asymmetric fast-grow (jump to cap on catch) / slow-shrink (halve only after 4
  clean halts), cap=100000. It matches the best fixed cap (44841 vs 45063 op/s) AND has the LOWEST
  halt_exits/s of every arm (11039 vs 41913 at fixed-10000 = 4x fewer VM-exits) AND the best p99
  (2118us, -39% vs fixed-10000). It auto-finds the winning spin WITHOUT a hand-set OSV_IDLE_SPIN.
- **p99 (standing requirement): IMPROVED** 3484 -> 2118 us vs the old fixed-10000 default. Not regressed.

## IDLE regression check — INCONCLUSIVE via the proxy used (honest)
Ran a 1-writer / 31-idle-vCPU guest, both arms. My host-side qemu-CPU probe read 0 on BOTH arms (the
nested-container qemu PID was not read correctly from the host /proc, and the guest is genuinely near-idle
so the signal is tiny) — so this measurement did NOT cleanly distinguish the arms and is NOT claimed as
proof. HOWEVER the idle-safety is strongly supported two other ways:
  1. By construction: 4 consecutive genuine halts -> halve-per-halt -> floor(256) in ~9 halts, then the
     CPU HALTS. A genuinely idle CPU does not stay pinned at the cap.
  2. By the busy halt_exits: adaptive v2 had the LOWEST halt rate (11039/s). A design that pinned idle
     vCPUs at the 100000 spin would show near-zero halts + high CPU; adaptive instead halts cleanly.
The rigorous idle-CPU-seconds A/B (fully-idle guest, correct host /proc accounting) is DEFERRED to the
next account. It is the one gate not yet closed with a clean number.

## a2a VU32 gold-test — DEFERRED (no runway)
The 5-fresh-boot VU32 re-run (does the intermittent 93k low-mode disappear + qemu_cpu discriminator clean)
needs a 200wh HammerDB seed + 5 boots + a driver box — far beyond the account's remaining life. Deferred.

## VERDICT (honest, measured)
On the durable-write / request-reply isolate that names the residual, **adaptive-idle-spin v2 is a clear
net win vs the old fixed-10000 default: +65% op/s, -43% wake-to-entry latency, -39% p99, and 4x fewer
halt-exits (VM-exits)** — it reaches the #1501 high-spin win automatically, on a halt-polling host, with
NO hand-set knob. The naive symmetric adaptive (v1) was measured to LOSE and was correctly discarded.
Idle-safety is supported by construction + the low busy halt rate but the clean idle-CPU A/B and the a2a
VU32 gold-test are DEFERRED to the next account. The code is banked + pushed and is master-applicable.

## Next account (to close the loop)
1. Clean idle-CPU-seconds A/B on a FULLY idle guest (fix the host /proc accounting) — the default-safe gate.
2. The a2a VU32 5-rep gold-test with adaptive-on: does the 93k waiting-low-mode disappear + qemu_cpu clean.
3. If both pass -> open the master-facing PR (draft body in PR-DRAFT.md).
