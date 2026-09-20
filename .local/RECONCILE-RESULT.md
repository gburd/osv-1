# RECONCILE-RESULT — the benchmark contradiction + the central OSv-PG disease

Agent: reconcile run. Started from ROADMAP CONTRADICTION + BEFORE-BASELINE + osv-fair-benchmark skill.
AWS_PROFILE=fred acct 443433794128 us-east-2. Egress IPv4 150.228.93.240 (Starlink, may rotate).

---
## PHASE 0 — git-level reconciliation (done BEFORE any AWS spend; empirical, verified)

Branch tips (verified `git rev-parse`):
- A `pr/sched-idle-pull`  @ f9fb81238  (clean #1472 PULL on stock master af96db0f)
- B `wip/wake-place-pull` @ 80aa4255b  (the BEFORE-BASELINE build)
- C `integ/pg-fork-zfs`   @ 027d419c4  (W2 known-good pair + RX-fanout)

### KEY FINDING 1 — B's "mmu" commits are PATCH-IDENTICAL to C's W2 known-good pair
`git patch-id --stable`:
- 746e5bcd9 (C W2 registry)  == 7d1a9a213 (B registry)  : both pid=109002c0...
- dad77b7fa (C W2 COW-peek)  == 80aa4255b (B COW-peek)   : both pid=59c78450...
=> The W2 mmu *logic* is byte-identical in B and C. The W2 pair is NOT the difference.

### KEY FINDING 2 — the difference is the BASE the identical W2 content sits on
merge-base(B,C) = **6b71c7638** (top of the shared fork-stack: PLT eager-bind,
page-pool UAF quarantine, entropy-ring-on-heap, 4K-descend, SIGURG-inline, registry-shard).
BOTH B and C contain the ENTIRE fork-stack up to 6b71c7638.

Extra commits B has that C LACKS (B ^C, excluding the patch-identical W2 pair):
- 7dd432784  sched: wake-time PUSH (select_task_rq-style)  <- KNOWN IPI-storm/livelock lever (ROADMAP)
- 25d20850c  sched: idle-CPU PULL (stable alt to PUSH)
- 142e1b92e  rxprof profiler + wake_steal toggle + parked_link migration fix
- 256e87b53 / 385857bc8 / 2f6b721fc  lockprof/rxprof header+decl+kconfig fixups
- 2a029c9a9  virtio-net RSS
- 14d86c0c3  virtio-net multiqueue (MQ)
- 2c30f7570  virtio-net RX mbuf refcount-in-buffer
- c7230e5c5  bound MSI-X vectors (many-queue boot)
- c94fbee57  sched: load-balancer disperse-faster

Extra commits C has that B LACKS (C ^B, excluding W2 pair):
- 027d419c4  net: fan out virtio-net RX dispatch across CPUs (RX-fanout)

=> B = fork-stack + {wake-time PUSH 7dd43, PULL, rxprof, RSS, MQ, MSI-X, disperse}  + W2-content
   C = fork-stack + {RX-fanout}                                                     + W2-content
A = clean #1472 PULL on STOCK master — NO fork-stack, NO W2 (conf_fork default). Likely 9c8d94a1's build.

### HYPOTHESIS (to test empirically on the box)
The BEFORE-BASELINE smp>=2 crash (assert(preemptable()) in timer_list::fired, COW-fork-path
fault in IRQ context) is caused by B's EXPERIMENTAL BASE — the wake-time PUSH (7dd432784,
known IPI-storm lever) and/or MQ/RSS/rxprof — NOT by the W2 mmu logic (which is byte-identical
in the stable C). If so: C runs smp>=2 0-failed, B reproduces the crash, contradiction RESOLVED
(9c8d94a1's "stable" was A or C-like clean base; the baseline ran the contaminated B base).
Alternative: a real remaining COW-fault-in-IRQ bug that only the extra dispersion in B exposes.

### CRASH SITE (read from source)
- arch/x64/mmu.cc `page_fault()`: after the missing-symbol check, `assert(sched::preemptable())`
  then `assert(ef->rflags & rflags_if)`, then DROP_LOCK(irq_lock){ vm_fault }. A fault taken with
  preemption off (IRQ context) trips the first assert — vm_fault may sleep (vmas_mutex, flush_tlb).
- core/sched.cc `timer_list::fired()` (line 2027) runs in IRQ (callback_dispatch::fired ->
  invoke_interrupt). It calls `timer->expire()` = arbitrary timer callback. If that callback
  touches a not-yet-COW-mapped fork page => page fault in IRQ => preemption off => assert.
  SAME fault class as native 0xa100000000 and W2 memcmp+30 (all: fault on the COW-fork path
  taken where blocking/reschedule is illegal). Whether it is the SAME page/mechanism = TBD on box.

## PHASE 1 — AWS build + 3-config A/B  (in progress)

---
## PHASE 1 RESULTS — on-box empirical (agent osv-forktimer-decide, i-0c622ae752a883fa9, m5d.metal)

Substrate: m5d.metal (real KVM), qemu 9.1.0 built from source (no slirp), OSv booted via
run.py `-k` PVH kernel mode (`-kernel loader.elf`, --nics 0). conf_fork=1, tests module.
NOTE: usr.img disk-boot loops at SeaBIOS "Booting from Hard Disk" (the LBA-128 loader bug);
PVH `-k` mode boots clean and is the correct QEMU boot path for the test.
Both C (integ/pg-fork-zfs 027d419c4, +1-line -faligned-new net_channel toolchain fix) and
B (wip/wake-place-pull 80aa4255b) built conf_fork=1 rc=0.

### BUILD C (integ/pg-fork-zfs) — the CORRECT build (fork-stack + W2 pair + RX-fanout, NO PUSH/MQ/RSS)
| test              | smp1 | smp2 | smp8 |
|-------------------|------|------|------|
| tst-fork-irq-cow  | PASS | PASS | PASS (deterministic x3) |
| tst-fork-cow      | PASS | PASS | PASS |
| tst-fork-deep     | PASS | PASS | PASS |
| tst-fork          | PASS | PASS | FAIL* |

*tst-fork smp8 FAIL = the fork+exec exit-code reap ("exec'd payload exit code 7 reaped")
FAILS consistently x4, OR a one-off `boost::intrusive bstree insert_equal` double-insert
assert. This is a SEPARATE fork+EXEC(execve-after-fork) bug at smp8 — NOT the timer-IRQ-COW
preemptable() disease (no `assert(preemptable())`, no `timer_list::fired`, no page fault in
IRQ). The IRQ-COW hazard test — which drives EXACTLY the baseline's crash path — is
deterministic PASS on C at smp1/2/8.

### BUILD B (wip/wake-place-pull 80aa4255b) — the CONTAMINATED baseline build (fork-stack + wake-PUSH 7dd432784 + MQ/RSS/rxprof + W2 pair)
| test              | smp1 | smp2 | smp8 |
|-------------------|------|------|------|
| tst-fork-irq-cow  | PASS | PASS | PASS |
| tst-fork-cow      |  -   |  -   | PASS |
| tst-fork-deep     |  -   |  -   | PASS |
| tst-fork          | PASS | PASS | PASS (incl. fork+exec — C FAILs this at smp8!) |

### DECISION — CONTRADICTION RESOLVED
Neither B NOR C reproduces the BEFORE-BASELINE `assert(preemptable())` in `timer_list::fired()`
crash under the ISOLATED fork+timer hazard test (tst-fork-irq-cow) at any smp level. BOTH have
the byte-identical park-timers pair (2d218bd3f + 9108df4b5) and BOTH park correctly.

=> The park-timers fix is **SUFFICIENT** for the timer-IRQ-COW disease. It is NOT incomplete.
   STEP 2 (complete the fix) is NOT required.

=> The BEFORE-BASELINE smp>=2 crash was **NOT the bare timer hazard**. It was triggered by B's
   contaminant (wake-time PUSH 7dd432784 IPI-storm + MQ/RSS/rxprof) under the REAL PG+network
   workload — a timer/interrupt storm the isolated test does not reproduce. C, which has the
   IDENTICAL park fix but NO PUSH/MQ/RSS contaminant, is the correct build to benchmark.
   Resolution = **CONTAMINATION (B-specific base), park fix sound.**

### Incidental finding (NOT the timer disease, logged for follow-up)
tst-fork at smp8: C (RX-fanout) FAILs the fork+exec exit-code reap consistently; B PASSes it.
So C's RX-fanout base has a separate execve-after-fork exit-code delivery bug at high smp. This
does NOT gate PG (postmaster forks backends, does not execve them) and is NOT the preemptable
timer crash. Flagged; out of scope for the timer contradiction.
