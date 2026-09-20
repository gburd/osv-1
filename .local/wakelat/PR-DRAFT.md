# DRAFT PR: sched: adaptive per-CPU idle-spin window (guest-side halt-polling)

## Openable? YES — master-applicable, not fork-stack-blocked.
core/sched.cc do_idle() / idle_poll / send_wakeup_ipi() ALL exist on upstream/master (verified) with the
identical idle_poll IPI-suppression handshake and a hardcoded 10000 spin. This change replaces that fixed
count with an adaptive window. It does NOT depend on the fork/ZFS/pagecache fork-stack. It DOES sit on top
of the fork's #1472 wake-pull (CONF_sched_wake_pull) and #1501 (OSV_IDLE_SPIN) in this branch, but the
core diff (the adaptive window in do_idle) rebases cleanly onto master's do_idle. For a master PR: port the
do_idle body + the idle_spin_window/idle_halt_streak fields + idle_spin_max()/idle_spin_adaptive() onto
master's do_idle (drop the CONF_sched_wake_pull try_pull_from_busiest line, which master lacks).

## Title
sched: adaptive per-CPU idle-spin before halt (guest-side halt-polling)

## Body
An idle CPU spins polling incoming_wakeups before halting via arch::wait_for_interrupt (a VM-exit under
KVM). send_wakeup_ipi() already suppresses the cross-CPU wake IPI while the target is still spinning
(idle_poll==true), so a wake caught during the spin costs no IPI and no VM-exit, while a wake to an
already-halted CPU costs an IPI -> VM-exit round-trip.

The spin was a FIXED 10000 iterations. A fixed count is the wrong control: too short and a to-be-rewoken
thread's vCPU halts just before its wake (the expensive path); too long and it burns cycles when genuinely
idle. This replaces it with an adaptive per-CPU window, like Linux's adaptive KVM halt-polling
(halt_poll_ns) but on the guest side — so it helps even where the host halt-polls (a fixed guest spin is a
no-op there; an adaptive one that tracks the wake rate is not).

The grow/shrink asymmetry is essential (a symmetric double/halve was measured to LOSE to the fixed count
on a busy workload, because a busy CPU that halts occasionally decays and then polls LESS than the fixed
count):
  - caught a wake mid-spin -> jump the window to the cap + reset the halt streak (stay fully polled);
  - halted without a wake -> only after 4 consecutive genuine halts (a single halt on a busy CPU is
    normal) does the CPU look truly idle; then each further halt halves the window toward a floor (256),
    so a genuinely idle CPU decays and halts, letting the host reclaim the vCPU.

Measured on a 32-writer durable-write (ZFS fdatasync) isolate on an m5d.metal (qemu 7.2.22, host KVM
halt_poll_ns=200000), adaptive vs the old fixed 10000:
  throughput  27200 -> 44841 op/s  (+65%)
  wake-to-entry latency  137 -> 78 us  (-43%)
  p99  3484 -> 2118 us  (-39%)
  KVM halt_exits  41913/s -> 11039/s  (4x fewer VM-exits)
It reaches the high-spin win automatically, with no hand-set knob, and decays to the floor + halts when
idle. OSV_IDLE_SPIN sets the cap; OSV_IDLE_SPIN_ADAPTIVE=0 pins the fixed-count behavior.

## FLAG FOR OWNER
Before opening: (1) close the clean idle-CPU-seconds A/B on a fully-idle guest (the proxy run this session
was inconclusive), and (2) ideally the a2a VU32 gold-test (does the intermittent wakeup-starved low-mode
disappear). The busy-isolate win + p99 improvement + 4x-fewer-VM-exits are solid and reproduced the #1501
effect; the idle gate is the one number to nail before it is a confident default-safe master PR.
