# The post-commit wakeup fan-out: traced. The M1 ceiling, mechanism-level.

## The chain (ONE completion thread wakes N backends per commit batch)
    zil_lwb_flush_vdevs_done (runs on the zio completion path, one thread):
      mutex_enter(zilog->zl_lock)                          <- held across the WHOLE fan-out
      while (zcw = list_remove_head(lwb->lwb_waiters)):     <- N waiters batched into this lwb
        zil_commit_waiter_done(zcw):
          mutex_enter(zcw->zcw_lock)                        <- per-waiter, uncontended
          zcw_done=TRUE; cv_broadcast(zcw_cv)               <- OSv condvar::wake_all
            -> send_lock(zcw_lock, wr)                      <- uncontended -> wr->wake()
              -> thread::wake_impl:
                   incoming_wakeups[c].push_back(backend)
                   if mask bit clear: send_wakeup_ipi(tcpu) <- IPI to backend's home CPU
          mutex_exit(zcw->zcw_lock)
      mutex_exit(zilog->zl_lock)

## What is and is NOT the cost (traced, verified in source)
- Each zcw has its OWN zcw_lock + zcw_cv, single waiter -> cv_broadcast is NOT cross-contended.
- The IPI is ALREADY async + coalesced PER (waker,target): a 2nd wake from the same waker to the same
  target CPU skips the IPI. But the completion thread wakes N backends on N DISTINCT home CPUs (fork
  placement + load balance spreads them across ~all 32 vCPUs), so it sends ~N IPIs, one per target.
- The SERIAL cost is: the loop bookkeeping (N x send_lock + push_back + mask + IPI-poke) all under
  zilog->zl_lock, on ONE thread, while N backends sit in NULL-wait. send_wakeup_ipi is async (pokes,
  does not block), so it is not N blocking round-trips - but each IPI still forces a VM-exit/re-entry
  on a HALTED target vCPU (~1-3us of hypervisor cost), and the loop cannot overlap them well.
- wake-pull CANNOT help: the backends are NOT runnable-and-unplaced, they are NOT-YET-WOKEN. The waker
  IS the bottleneck.

## THREE candidate levers, to DISCRIMINATE by measurement (do NOT build first - 4 prior wrong guesses)
1. **zilog->zl_lock held across the fan-out.** If the walk is long, backends and the next commit stall
   behind it. Fix: collect the waiters under the lock, wake them AFTER releasing it. Small, safe.
2. **The VM-exit-per-IPI to halted vCPUs.** This is a HYPERVISOR cost. On BARE METAL (no VM-exit) it
   largely vanishes. This is testable ONLY by a native run - and directly bears on the operator's
   substrate point: part of the wakeup cost may be the VM boundary, not OSv.
3. **The serial single-waker loop.** N wakes on one thread. Fix: fan the wake out (e.g. the completion
   thread wakes waiter 0 which wakes 1..N, or a wake-list processed in parallel). Bigger change.

## THE MEASUREMENT that discriminates (cheap, before any fix)
Instrument zil_lwb_flush_vdevs_done with gethrtime() around: (a) the whole fan-out, (b) per-waiter wake,
(c) count N (waiters per lwb). Run the concurrent syncwrite isolate (threads=8/16/32) with this probe:
  - If total fan-out time grows linearly with N and dominates the commit latency -> the serial loop is
    the gate (lever 1 or 3).
  - If per-wake time is large (~us) and IPI-dominated -> lever 2, and a NATIVE run should shrink it.
  - Compare the SAME probe under qemu vs native (bare metal): if per-wake collapses on native, the
    VM-exit-per-IPI was the cost and the "fix" is partly deploy-on-metal, not a code change.

## THE CLEANEST NEXT EXPERIMENT (ties together the operator's substrate directive)
Run the concurrent syncwrite isolate on BARE METAL (OSv as the only thing on the instance, no qemu, no
FC) vs under qemu, SAME build. If the wakeup fan-out stall is a VM-exit-per-IPI artifact, native scales
where qemu plateaus - and the M1 fix is "deploy native" + maybe lever 1 (cheap zl_lock hoist). If it
persists on native, it is purely OSv's serial single-waker fan-out and lever 3 is the real fix.
This is the FIRST measurement to run - it splits "OSv code" from "VM boundary" for the wakeup path,
which is exactly the question the operator's QEMU/Firecracker/native framing was driving at.

## Note: lever 1 (hoist the wake out of zl_lock) is small and safe enough to prepare NOW as a candidate,
## but it must be A/B-measured (env-gated) not assumed - and the native-vs-qemu split comes first.

## CORRECTION (2026-09-14): lever 2 (VM-exit-per-IPI) is NOT the differentiator. The fix is OSv-side.
Two reasons, both decisive:
  1. The VM-exit-per-IPI cost is the SAME for OSv and Linux under the same hypervisor. It cannot
     explain the OSv-vs-Linux gap.
  2. Linux ALSO pays IPI/VM-exit cost on wakeups and STILL scales to 269k. So scaling despite VM-exit
     IPIs is demonstrably possible. The differentiator is HOW the wake fan-out is done: OSv wakes N
     backends SERIALLY on ONE completion thread (under zilog->zl_lock); Linux completes I/O in
     IRQ/softirq context and wakes waiters without funnelling them through one serial kernel thread.
Also: "native" in the prior matrix = m5d.2xlarge (still a cloud-KVM guest, not bare metal), and the
tail REPRODUCED there too. True bare-metal is a hard OSv boot path (UEFI/PXE, real NVMe/NIC drivers) and
a big detour - do NOT design the discriminator around it.

## REFINED PLAN: measure the fan-out timing on the isolate (no new substrate needed)
Instrument zil_lwb_flush_vdevs_done with gethrtime() around the whole fan-out + per-waiter wake + count
N. Run the concurrent syncwrite isolate (threads=8/16/32) under the SAME qemu. Discriminate:
  - total fan-out time linear in N and dominating commit latency -> serial loop is the gate (lever 3).
  - a large chunk of that time is the zilog->zl_lock hold (next commit blocked) -> lever 1 too.
Then the fix (both are OSv-side, help on any substrate):
  Lever 1 (cheap, safe): collect waiters under zl_lock, DROP the lock, then wake them - so the next
    commit and the woken backends do not stall behind the fan-out. Env-gated A/B.
  Lever 3 (bigger): parallelize the wake fan-out (wake off the single completion thread, or a
    self-propagating wake chain, or wake from the per-queue completion threads #1509 added).
Measure -> build the named lever -> A/B on the isolate (expect fan-out time drop + isolate throughput
rise at threads=16/32) -> HammerDB confirm. Substrate stays qemu for the isolate (fix is OSv-side);
the eventual HammerDB confirm should be on the Debian host per the directive.

## DISPATCHED (agent 0fd43f40, 2026-09-14): measure the fan-out, then fix.
STEP 1: instrument zil_lwb_flush_vdevs_done (N waiters, total fan-out time, wake-loop time, zl_lock
hold), run the concurrent isolate threads=8/16/32, discriminate lever 1 (zl_lock hoist) vs lever 3
(parallel fan-out) vs REFUTED (N~1, not batching -> elsewhere).
STEP 2: build the named lever, env-gated A/B on the isolate.
STEP 3: report for a separate HammerDB confirm.
Substrate: DEBIAN 12 host (ami-0dc1629a58a7d6458) per directive - first test of native qemu 7.2 booting
OSv without the fedora container / -M pc hack. If that works it also validates the new substrate for all
future runs. Tag Owner=agent-zilwake.

## The through-line of the whole M1 investigation (for the record)
The gap narrowed and localized in stages, each by measurement, each refuting a plausible guess:
  matched baseline (4.9x was a handicapped-baseline artifact; real matched gap 1.5x@VU8 widening) ->
  fsync O(filesize) scan (#1507, real, checkpoint+tail win, NOPM null) ->
  dentry AB-BA deadlock (#1502, real, clears the VU32 wedge, NOPM ~unchanged) ->
  block-completion drain (#1509, real isolate +58%, HammerDB null - device idle) ->
  post-commit WAKEUP FAN-OUT (this - the serial single-waker cv_broadcast under zl_lock).
Each fix is a real, generic, upstreamable OSv improvement (G2) even where it did not move NOPM. The
wakeup fan-out is the current frontier; if it also nulls, the next candidate is the fork/backend model
itself (process-per-connection tail), but the fan-out is the mechanism the NULL-wait signature names.
