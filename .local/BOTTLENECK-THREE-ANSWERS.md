# CORRECTED (2026-09-08, same day): the x86 "CPU/guest-bound" verdict is RETRACTED

The agent that produced it retracted it before I could act on it, and the arithmetic is decisive.

    qemu CPU during the VU32 window : 40-50% of ONE core
    ceiling at 32 vCPU              : 3200%
    => the guest used ~1.6% of its available CPU, with the host 99.8% idle

So 25-32 backends reporting `state=active` while consuming 1.6% of available CPU refutes
"CPU-bound" by roughly 60x. **The underlying error, worth naming: PostgreSQL `state='active'`
means "not waiting on a REGISTERED wait event", NOT "on CPU".** A backend blocked in something
OSv does not surface as a PG wait event is indistinguishable from a backend doing arithmetic.

I accepted the inference from an interim message without checking it against a host-side counter.
Same mistake as always: I took a derived signal as a direct one.

## The corrected, stronger finding: an UNATTRIBUTED STALL

At VU32 on OSv x86, in steady state:
- device is NOT the limit: 12-19% %util, w_await 0.16-0.26 ms
- `LWLock:WALWrite` is NOT the queue: only 1-5 of 32 backends
- yet the guest consumes ~0.5 of 32 vCPU

**The work is neither on the device nor on a CPU.** That points at OSv-side blocking that no
PostgreSQL wait event surfaces - scheduler/idle behaviour, or an internal wait with no PG-visible
attribution. Labelled **unattributed stall** deliberately; upgrading it to a named mechanism
without evidence is what produced three wrong theories for the dlopen bug.

Consistent with, but NOT the same as, the aarch64 idle-device observation: there the backends were
queued on `LWLock:WALWrite`, here they are not.

---
# The bottleneck question has THREE answers, not two

2026-09-08. I posed this as a binary - "is `LWLock:WALWrite` on an idle device an OSv defect, or
is it PostgreSQL's WAL design?" - and instructed both arms to settle it. The measured answer is
that the question had a third case I did not anticipate.

    arm                            wait events                       device %util      verdict
    Linux/PG18.6 (16 vCPU VM)      LWLock:WALWrite 55/64             73-93% BUSY       PostgreSQL WAL design
    OSv aarch64  (32 vCPU metal)   LWLock:WALWrite 20-31/32          1.34-2.80% IDLE   OSv-side cost
    OSv x86      (32 vCPU metal)   RUNNING 25-32/32, WALWrite 1-5    12-19%, w_await   CPU/guest-bound
                                                                     0.16-0.26 ms

## What each answer means
- **Linux**: the lock queue is the expected consequence of a nearly saturated device. Not a defect.
- **aarch64 OSv**: the same queue with the device 98% idle. A genuine OSv-side serialization cost.
- **x86 OSv (new)**: almost every backend is ON CPU, barely any in the WAL lock, and the device is
  only 12-19% busy. So x86 is **CPU/guest-bound**: neither the WAL lock nor storage is the ceiling.

**The discriminator remains `%util` alongside the wait events, never the wait-event name.** Had we
only collected wait events, all three arms would have looked like "a WAL problem" and two of the
three conclusions would have been wrong.

## It also retires a banked conclusion of mine
The previous x86 report concluded "ZFS COW write amplification at recordsize=8k", ~59.9 MiB/s,
"~56% of achievable". **Artifact.** Those three checkpoints are labelled post-recovery, mid-load
and pre-crash, from a run that never reached a timed window - so they measured crash-recovery WAL
replay and rampup, not the benchmark. Marked as superseded in
`.local/X86-RESULTS-2026-09-07.md` rather than deleted, with the reason.

Lesson: **a number measured during crash recovery is not a steady-state number**, and a run that
crashed before its timed window cannot characterise a bottleneck at all. I banked one anyway.

## Open follow-up (scheduled, not urgent)
If 25-32 of 32 backends are on CPU with an idle-ish device, where are the cycles going? A coarse
guest profile at VU32 would point at the next fix. Explicitly told the arm NOT to let this
displace finishing the sweep; a complete VU 8/16/32/64/96 x 3 repeats is worth more than a partial
sweep plus a profile.

## Cross-arm contrast that localises the aarch64 problem
`max_wal_size=64GB` worked mechanically on BOTH arms (timed checkpoints now dominate, zero
WAL-triggered), but:
    x86:     spread collapsed 30-35% -> **0.8-6.3%**, all under the 15% gate
    aarch64: spread still **27.6% / 29.7%**
Same knob, same effect on checkpoint scheduling, very different effect on variance. So the
residual aarch64 variance is ISA- or arm-specific and is now localised rather than mysterious.

## Methodology note worth reusing
**HammerDB 6.0 deprecated `runtimer`**, so `vudestroy` can fire before virtual users drain,
yielding "Virtual Users remain running in background or shutting down, retry" on a perfectly
healthy guest (0 page faults, PG still serving). My briefs have specified `runtimer` to multiple
agents. Use a **`vucomplete` poll** instead. This is exactly the class of harness defect that gets
misreported as a platform failure.
