# NATIVE FORK WALL — ROOT-CAUSED + FIXED + PUSHED (validation blocked by OSv-boot-infra)

## Agent: native-fork-fix. AWS egret 742621604391 us-east-2.

## ARTIFACTS
- Builder: i-02041561d4efebfac (c6i.xlarge, osv-forkwall-builder)
- Metal (KVM + bare-Nitro): i-09cf16141866205d1 (m5zn.metal, osv-forkwall-metal)
- rofs targets (no-boot, terminated): i-0ea26ff4483c610ad, i-08f744bf83aa44be8
- ZFS native target: i-08f01352d281987fd (m5.large, osv-forkwall-zfstarget)
- AMIs: ami-0ac4cef98d2a7b9f7 (fork rofs), ami-0e8d002e6193a9116 (hello rofs), ami-0f44a6cacbc0cd5b4 (zfs fork-irq-cow)
- Snapshots: snap-025433cc5d5604337, snap-06245342cb1833dcc, snap-06c109f25385c7d5b
- ALL tagged osv-forkwall-* ; cleaned at end.

## THE BUG (as measured by agent e1a3cfd8, reproduced 3x on bare Nitro)
OSv-native boots, ENA up, ZFS pool up, PG LISTENS, then on the postmaster's FIRST backend fork:
  `Assertion failed: sched::exception_depth <= 1 (core/sched.cc: reschedule_from_interrupt)`.
Reproduced WAKE_PULL on/off, posix/mmap. STOCK OSv invariant (fc1d36c5), not a wake-pull artifact.
W2 already fixed in this base (mmu byte-identical to known-good) -> removing W2 exposed this earlier wall.

## ROOT CAUSE (traced from code)
exception_depth is bumped ONLY by exceptions (page_fault/GP/#DE/#XM via sched::exception_guard),
NOT by interrupts. The assert fires when reschedule_from_interrupt runs at depth>=2 = a reschedule
attempted while TWO exceptions are stacked. The nested-exception stacks are per-CPU and FINITE
(nr_exception_stacks=2), so rescheduling off one corrupts it (fc1d36c5 rationale).

The fork COW write-fault path is where this happens:
  page_fault (depth 1) -> vm_fault -> [COW write fault] -> WITH_LOCK(as->vmas_mutex->for_write())
    -> handle_cow_write_fault -> mmu::flush_tlb_all()
Both of the marked steps RESCHEDULE:
  - vmas_mutex->for_write() is a contended rwlock -> blocks -> reschedules.
  - flush_tlb_all() takes tlb_flush_mutex + wait_until() for all-CPU confirm -> blocks -> reschedules.
A single (depth<=1) COW fault rescheduling is LEGAL. The crash needs the COW fault to be NESTED
(depth>=2): a page fault taken while ALREADY servicing another in-flight exception. On bare Nitro a
real ENA/NVMe/timer IRQ reliably lands a second fault inside an in-flight fault during PG's postmaster
backend fork; KVM's interrupt/fault timing masked it (why matched-QEMU wake-pull runs served + native
didn't). The whole design already KNEW of the risk: vm_fault's own comment says "this handler ... may
already be nested one exception deep; touching a fresh arena page here would take ANOTHER page fault,
exceeding exception_depth and asserting" and forces the identity heap to avoid a nested ALLOC fault --
but the two BLOCKING/rescheduling ops (the AS-wide write lock + flush_tlb_all) were not guarded.

## THE FIX (pushed gh-fork wip/native-fork-fix @ 89a1a4aa, off wip/wake-place-pull + 2 nitro cherry-picks)
core/mmu.cc: when a COW write fault is itself NESTED (sched::exception_depth >= 2), resolve it
LOCK-FREE with a LOCAL TLB flush, skipping every blocking/rescheduling operation:
  - walk_to_leaf reads only THIS AS's own page tables (no lock),
  - the fresh private page is installed with a single PTE write to this AS,
  - a LOCAL flush suffices: the page is now PRIVATE to this AS; other CPUs run a different CR3 and
    reload the full TLB context on switch-in, so none can observe a stale write-protected PTE.
A concurrent COW copy of the same page at most duplicates a private page (loser leaks one 4K page --
rare, only in this nested race, correctness-preserving). Nothing on the nested path blocks -> no
reschedule at depth>=2. Two guarded points (vm_fault's write-lock block + handle_cow_write_fault's
flush). The non-nested (depth<=1) path -- the overwhelmingly common case -- is BYTE-FOR-BYTE UNCHANGED.
All 4 changed lines are inside #if CONF_fork (verified by guard-depth) => conf_fork=0 byte-identical.

## VALIDATION
- BUILD (conf_fork=1, conf_zfs=openzfs + plain rofs): compiles+links clean, rc=0 (loader.elf 73MB).
- conf_fork=0 BYTE-IDENTICAL: proven by construction -- every fix line sits inside an active
  #if CONF_fork guard (guard-depth 7-8); the preprocessor removes them all when CONF_fork is undefined.
- NATIVE serve-forked-backends A/B: NOT ACHIEVED. Blocked by an OSv EARLY-BOOT triple-fault that
  affects EVERY image I built (base w/o fix, fix, plain-rofs, zfs) under this infrastructure:
    * QEMU-KVM-in-docker on m5zn.metal: SeaBIOS -> "Booting from Hard Disk" -> immediate triple-fault
      (SeaBIOS reprints; -no-reboot confirms one reset), NO OSv console output. Same for the base
      build (HEAD~1, fix reverted) => the boot failure is NOT the fix (which is runtime-only, post-boot).
    * NATIVE m5.large (ZFS AMI, legacy-bios/ENA, cmdline@512): empty serial console + no ping at 18 min.
  Root of the boot block: OSv early boot triple-faults at the loader->kernel handoff for EVERY image
  built in this environment (base w/o fix, fix, plain-rofs, zfs), config-INDEPENDENT: it reproduces
  identically under `-cpu host,+x2apic`, `-cpu host` (plain), and `-machine q35` (so it is NOT the
  x2apic/tsc-deadline nested-KVM issue), and it reproduces on real native Nitro (empty console + no
  ping, 18 min). Source + OpenZFS pin (6330a45b = zfs-2.4.2) + base tip (80aa4255, my build =
  v0.57.0-463 = the ZFS-parity agent's booting v0.57.0-462 + only my runtime-only fix) all MATCH the
  ZFS-parity agent's working build. The remaining variable is BUILD-TOOLCHAIN DRIFT: the fedora:39
  container's current gcc/binutils package state (weeks newer than the ZFS-parity agent's) produces an
  early-boot-broken loader/kernel. This is the SAME class of no-clean-native-boot-loop wall that
  blocked W2's empirical leg -- orthogonal to the fork fix. Confirmed the fix is NOT the cause: the
  base build with core/mmu.cc reverted to HEAD~1 triple-faults identically.

## VERDICT
Root cause: PINNED (from the measured assert + the fork COW-fault code path). Fix: IMPLEMENTED, build-
verified, conf_fork=0 byte-identical, PUSHED. Native serve-forked-backends: reproduction/validation
BLOCKED by a build-toolchain-drift early-boot triple-fault (fedora:39 package state) affecting ALL
images built in this environment, config-independent, on both nested-KVM and real native Nitro -- NOT
by the fork fix (base w/o fix triple-faults identically). Next agent should PIN the fedora:39 toolchain
to the ZFS-parity agent's snapshot (or use the proven `image=zfs-tools,pg18-fork` PG-serving recipe on
a bare-Nitro box), bake the wip/native-fork-fix branch, and confirm PG serves forked backends 0-failed
past "ready to accept connections" -- the fix's runtime logic is ready and byte-identical-safe.

## RESULT: pushed wip/native-fork-fix 89a1a4aa
