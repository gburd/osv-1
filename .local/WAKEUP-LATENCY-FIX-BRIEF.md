# Wakeup-latency residual: root cause + the adaptive-idle-spin fix (the named M1 residual)

## THE RESIDUAL (measured in the a2a capstone)
OSv trails Linux at VU32 median (0.72x) SOLELY due to an intermittent cross-vCPU WAKEUP-LATENCY low-mode.
Discriminator: the low VU32 rep ran qemu_cpu 0.5 vCPU + 43% NVMe = guest WAITING (not CPU/IO/wedge);
Linux VU32 stayed CPU-saturated ~20 vCPU with NO low-mode. OSv-specific. When it does not bite, OSv's
high mode (286k) overlaps Linux (265-314k). This is the last thing between "OSv leads at VU8/16" and
"OSv leads everywhere."

## ROOT CAUSE (localized in core/sched.cc, read end-to-end):
The wake path ALREADY suppresses the IPI when the target is idle-polling: send_wakeup_ipi() sends only if
(!idle_poll && runqueue.size()<=1). do_idle() sets idle_poll=true during a FIXED spin_count window
(idle_spin_count(), default 10000, OSV_IDLE_SPIN env). So:
 - target still SPINNING when the wake arrives -> waker skips IPI, target polls it up. CHEAP.
 - target already HALTED (spin exhausted -> wait_for_interrupt) -> waker must send IPI -> VM-exit. EXPENSIVE.
THE BUG IS THE CONTROL: a FIXED spin count is wrong. Too short -> a to-be-rewoken thread's vCPU halts
just before its wake -> IPI/VM-exit (the VU32 low-mode). Too long -> burns cycles when genuinely idle
(why #1501 is opt-in, not default). #1501 (OSV_IDLE_SPIN) is the blunt symptom lever + HOST-CONDITIONAL
(no-op where KVM halt-poll already catches the wake).

## THE ROOT-CAUSE FIX: ADAPTIVE idle-spin (guest-side, like Linux halt_poll_ns)
Spin LONGER when wakes are arriving frequently (busy request/reply - halting is a mistake, the next wake
is imminent), spin SHORT / halt FAST when genuinely idle (save cycles/power). Track a per-CPU adaptive
window: on each idle entry, if the LAST idle spin caught a wake before halting (a wake arrived mid-spin),
GROW the window (up to a cap); if it halted without catching a wake (genuinely idle), SHRINK it (toward a
small floor). This is exactly Linux's adaptive halt-polling, guest-side - so it works EVEN WHERE THE HOST
DOES NOT halt-poll (fixing #1501's host-conditionality). General OSv scheduler improvement: any cross-vCPU
wakeup-heavy workload (net/IPC/producer-consumer/DB) benefits, not just PG.

## DESIGN CONSTRAINTS
- Guest-side, per-CPU adaptive window in do_idle() (core/sched.cc). Preserve the existing idle_poll
  IPI-suppression handshake (send_wakeup_ipi already reads idle_poll - keep that).
- Bound: a MAX window (do not spin forever - a truly idle CPU must still halt to save the host) + a floor.
- Default behavior: adaptive should be a NET WIN or NEUTRAL vs the current fixed-10000 on BOTH a busy
  workload (grows to catch wakes) AND a genuinely-idle system (shrinks, halts, no cycle-burn regression).
  If it cannot be made default-safe, gate it (OSV_IDLE_SPIN_ADAPTIVE) - but the GOAL is a safe default,
  since the fixed count is demonstrably the wrong control.
- Do NOT regress the #1472 wake-pull (try_pull_from_busiest) or the CONF_lazy_stack invariants in do_idle.
- Interaction with host KVM halt-poll: where the host already halt-polls, adaptive guest-spin should
  detect "wakes always caught immediately / halts rarely" and NOT over-grow (no double-poll cycle-burn).
  Measure both a halt-polling host and a non-halt-polling host (the #1501 A/B found qemu 8.1.3 halt-polls,
  an earlier qemu did not - test both if feasible, or at least note which host).

## VALIDATION (must show it fixes the residual without a genuinely-idle regression):
1. The durable-write / request-reply ISOLATE (the syncwrite mt bench): adaptive vs fixed-10000 - op/s +,
   halt_exits/s down, wake2ent latency down. (This is where #1501 showed +56-140%.)
2. GENUINELY-IDLE regression check: a mostly-idle guest (a few conns, long think-time) - adaptive must NOT
   burn materially more CPU than fixed-10000 (it should SHRINK and halt). Measure guest CPU at idle.
3. THE REAL TEST - re-run the a2a VU32 cell (OSv, fresh-boot, io_uring, all fixes + adaptive spin): does
   the intermittent low-mode DISAPPEAR (all reps cluster high 195-286k, no 93k waiting-mode)? That is the
   residual fixed. Compare qemu_cpu on every rep - the low-mode signature (0.5 vCPU + waiting) must be gone.
4. p99 (standing requirement) - must not regress.

## Substrate: m5d.metal lava us-east-2 Debian 12, raw NVMe passthrough, base gh-fork bank/fork-arena-real-
## reclaim (the a2a base, gate-PASS, all fixes), apps 3f93f43. Bank a clean G-signed commit on a NEW branch
## (bank/sched-adaptive-idle-spin) - it stacks on / supersedes the #1501 fixed-count knob (note the relation
## to #1501). If adaptive is default-safe, it is a strong master-facing PR on its own (core/sched.cc, general).
