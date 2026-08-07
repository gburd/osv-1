# PostgreSQL-on-OSv North Star: Two-Milestone Program

Authoritative plan (2026-07-24). Supersedes ad-hoc fork-PG notes in ROADMAP.md
for the *goal framing*; the per-session mechanics stay in ROADMAP.md.

## The North Star (unchanged, now sharpened)
Run **unmodified PostgreSQL on OSv** at speeds that **match or beat PG-on-Linux**
on comparable VMs, proven under sustained **HammerDB** pressure, with the storage
stack that makes it production-real: **ZFS over a set of EBS volumes, using local
NVMe as L2ARC**, full ZFS tuning (compression, encryption, snapshots) with proven
durability. Both sides use **huge pages**.

## Milestone 1 -- Apples-to-apples parity: PG/OSv == PG/Linux
Definition of done:
1. **Stock, UNMODIFIED PostgreSQL (REL_19)** boots on OSv, reaches "ready to accept
   connections", and serves real queries (single + concurrent) via fork-per-backend.
2. **All PostgreSQL tests pass** on PG/OSv as configured for benchmarking (the
   regression suite the benchmark build runs -- not necessarily every check, but
   the suite green for our config).
3. **Storage:** /data on ZFS over a set of EBS volumes, local NVMe as **L2ARC**,
   full ZFS tuning (compression on, encryption, snapshots demonstrated durable).
4. **HammerDB** (TPROC-C / TPROC-H) sustained load: PG/OSv **on par or better**
   than PG/Linux, apples-to-apples:
   - PG/Linux on a well-known distro (Debian or Fedora), best-known OS tuning,
     identical Postgres + ZFS config, huge pages on.
   - PG/OSv same Postgres + ZFS config, huge pages on.
   - Same instance class, same EBS + NVMe layout.
   - Report throughput (NOPM/TPM), latency percentiles, and durability parity.
5. **Hypervisor / virtualization matrix:** PG/OSv must work -- and benchmark --
   **essentially identically across the target hypervisors**, not just one. The
   axis (test each, apples-to-apples):
   - **KVM** (qemu full virt) -- the current dev/bench path.
   - **Firecracker** (AWS microVM) -- THE production target for this workload
     (fast-boot, minimal device model, what you'd actually run PG/OSv on in
     prod). OSv already has first-class support: `scripts/firecracker.py` drives
     the Firecracker API (ELF `loader.elf` as kernel_image_path + boot_args,
     virtio-blk drive, virtio-net). Same virtio device model as KVM, so PG/OSv
     on Firecracker SHOULD behave identically -- prove it: same PG boots to
     "ready", serves rows, passes the suite, and HammerDB numbers are within
     noise of the KVM run on the same host. Any divergence (boot, device, perf)
     is a bug to root-cause. Firecracker on a bare-metal EC2 (nested KVM not
     required -- Firecracker runs directly on the metal instance's KVM).
   - **qemu_microvm** (the qemu equivalent of the Firecracker device model) --
     a useful local stand-in for Firecracker before the metal run; OSv supports
     it via `run.py --hypervisor qemu_microvm`.
   - (Cloud-provider variants -- GCE, other clouds' KVM -- are M1-adjacent; note
     but do not gate M1 on them. The gating pair is KVM + Firecracker.)
   Deliverable: the HammerDB A/B table has a hypervisor column; PG/OSv on
   Firecracker == PG/OSv on KVM (within noise), and both compared to PG/Linux.

### Milestone 1 remaining work (the bug ladder)
The fork mechanism + COW arena are DONE and validated (tst-fork 10/10,
tst-pgfork 9/9, tst-fork-preempt, tst-fork-cow/deep/execve; conf_fork=0 clean).
Stock PG boots to "listening", forks the checkpointer, then hits walls. Remaining,
in dependency order:

- **[W-mmap] fork-child mmap is not address-space-aware** (root-caused; own PR).
  vm_fault uses the child's `as->vmas`, but the ALLOCATION path
  (allocate/map_anon/find_hole/evacuate/find_intersecting_vma(s)/protect/unmap/
  mprotect/msync + the global vma_range_set) always uses the GLOBAL vma_list.
  A child's post-fork mmap lands in the global list, invisible to the child's
  fault handler -> #PF -> SIGSEGV. Deterministic, -smp 1, NOT preemption-dependent.
  FIX: thread `address_space*` (default = current thread's AS, kernel AS for the
  non-fork path so it stays byte-identical) through ~10 functions; give the child
  AS its own vma_range_set. `address_space` ALREADY holds `vmas`/`vmas_mutex`
  (child owns private, AS0 aliases global) -- so the fault path is already done;
  this extends the SAME pattern to the allocation path. ~65 vma_list refs +
  ~30 vma_range_set refs in core/mmu.cc to audit. Own PR + full mmu test pass.
  Gated CONF_fork ONLY where fork-specific; the AS-threading itself defaults to
  kernel AS so non-fork behavior is identical (this is the lazy-but-correct shape:
  one plumbing change, non-fork path unchanged).

- **[W-branch] PG wild indirect branch** (narrowed; needs KVM+hbreak). After
  "InitAux shmem read OK" the checkpointer takes an indirect branch (jmp*/call*,
  likely PLT `jmp *GOT[n]`) through a corrupt code pointer = 0x4b0000, with
  INTACT stack+regs. The .text there decodes to `mov $imm,%esp` which then
  destroys rsp (that's why earlier analysis mis-saw "rsp from .text"). NOT the
  scheduler switch (proven sound), NOT iret, NOT the FPU reload. HYPOTHESIS to
  test: this GOT/PLT slot was corrupted BY W-mmap (PG mmaps heavily at startup;
  a mislaid child mmap colliding with a GOT/relro page would corrupt exactly
  this kind of pointer). So **fix W-mmap first, then re-test PG** -- W-branch may
  vanish. If it survives: HW watchpoint under KVM+hbreak on the GOT slot / the
  store that writes 0x4b0000, to pin the exact corrupting write.

- **[W-shmem-grow, W-*] later PG startup walls** likely exist past the checkpointer
  (bgwriter, walwriter, autovacuum launcher, then the first real backend). Expect
  a few more allocation-context / AS-awareness / missing-syscall walls. Each is
  bounded and gdb-isolable; the pattern is well understood.

Once PG serves real rows (single + concurrent) reliably:
- Bring up ZFS-on-EBS + NVMe-L2ARC /data (the #1423 OpenZFS stack -- already
  runs at raw-device speed on OSv).
- Stand up the HammerDB A/B harness (PG/OSv vs PG/Linux) -- the aws-benchmark +
  pg-numa-benchmark skills cover the substrate.

## Milestone 2 -- Extension parity across PGXN
Definition of done: for **every PGXN-registered extension supporting REL_19**
(and common COMBINATIONS of them), verify it works **identically well on OSv as
on Linux**, exercised **under load using the extension's actual features** (not
just CREATE EXTENSION). For each extension:
- **PASS**: works on OSv equivalently to Linux under load.
- **FAIL -> (a) OSv gap**: something to fix/add/change in OSv (missing syscall,
  ABI edge, fs/mmap/threading behavior) -- file + fix.
- **FAIL -> (b) not-ours**: the extension itself is broken / relies on something
  that can't or shouldn't be provided by OSv (or is an extension bug) -- document,
  don't chase.
Deliverable: a matrix (extension x {OSv, Linux} x {load-feature results}) with
every FAIL categorized (a) or (b), and (a)-items turned into OSv fixes.
Prereq: Milestone 1 done (stock PG runs + benchmarks on OSv).

## Working principles for this program
- Stock/unmodified PG is the whole point -- every OSv-side deviation we had to
  make (WAIT_USE_SELF_PIPE, neutered checks, unix_socket_directories='') is a
  DEBT to erase, not a feature. Track each as an OSv gap to close so the final
  build is truly unmodified upstream PG.
- Every wall gets gdb-isolated + root-caused, not guessed (the experiments that
  overturned the "scheduler race" theory prove why).
- Fork/COW/AS work stays gated CONF_fork; the non-fork OSv path stays byte-identical.
- Fixes that are arena-INDEPENDENT and correct on their own get folded into the
  shipping fork PRs (#1455/#1456) to strengthen them; arena-only fixes stay on
  the integ branch.
- Honesty gate: no "PG works" without real psql rows; no "parity" without a real
  HammerDB A/B table.
- Hypervisor parity is part of "done": a result on KVM is not Milestone 1 until
  the same result holds on **Firecracker** (the production target). Validate on
  Firecracker as early as it's cheap (qemu_microvm local stand-in first, then
  Firecracker on bare-metal EC2), not only at the final benchmark.

## Current position on the ladder (2026-07-24)
Fork + COW + arena: DONE/validated. W-mmap (AS-aware mmu) DONE/validated (own-PR
shaped, non-fork byte-identical). PG boots to "listening" + forks checkpointer +
bgwriter, then hits W-branch (wild indirect branch / GOT corruption -- distinct
from W-mmap, confirmed). NEXT: KVM+hbreak on W-branch -> subsequent startup walls
-> real rows -> ZFS/NVMe /data -> HammerDB A/B on BOTH KVM and Firecracker = M1.

### Firecracker validation checkpoints (do at each stage, not just the end)
1. **Smoke (cheap, do once fork/PG boots under KVM):** boot the SAME PG image on
   `qemu_microvm` (`run.py --hypervisor qemu_microvm`) locally -- the microvm
   device model is Firecracker's twin. If PG behaves the same as KVM, that's the
   early signal parity holds. Any divergence here is a device-model bug caught
   cheaply before spending on metal.
2. **Real Firecracker (bare-metal EC2):** `scripts/firecracker.py` with
   loader.elf + usr.img + a tap for virtio-net. PG boots to "ready", serves rows,
   passes the suite. Confirm virtio-blk (ZFS-on-NVMe) and virtio-net behave
   identically to KVM.
3. **Bench parity:** HammerDB A/B gets a hypervisor column; PG/OSv-Firecracker
   must be within noise of PG/OSv-KVM on the same metal host, and both are the
   OSv side of the PG/OSv-vs-PG/Linux comparison.
Known OSv Firecracker facts: first-class support exists (scripts/firecracker.py,
same virtio-blk/virtio-net as KVM, ELF-kernel boot via the Firecracker API);
boot is PVH/direct-kernel (no SeaBIOS), which is also the qemu_microvm path --
so the fork/COW/arena work (all CPU + page-table + syscall, hypervisor-agnostic)
should need ZERO Firecracker-specific changes. If it does need changes, that's a
finding worth its own note.

## STANDING RULE: OpenZFS bugs -> the OpenZFS PR (#1423)
Using OpenZFS (conf_zfs=openzfs, NOT bsd) for PG is required -- it's how we test
PG/OSv/ZFS functionality + performance and how a real deployment would run.

Any bug found IN OpenZFS or in the OSv<->OpenZFS integration must be amended to
the OpenZFS PR (#1423, branch pr/openzfs-draft), so the fix ships WITH the
feature. Classify every ZFS-related fix:
- **Bug in OpenZFS itself** (libsolaris.so / the openzfs submodule) OR in the
  OSv OpenZFS compat/glue (bsd/sys/cddl/compat/opensolaris/*, modules/open_zfs/*,
  the vdev_disk/kmem/kstat/taskq shims, exported_symbols/osv_libsolaris.so.symbols,
  patches in modules/open_zfs/patches/) -> **amend to #1423 (pr/openzfs-draft)**.
  If the bug is in the pinned upstream openzfs submodule source, it becomes a new
  entry in the modules/open_zfs/patches/ series (the OSv-changes-as-format-patch
  model), applied at build -- NOT an edit to the submodule pin.
- **Bug in fork/COW machinery** (cross-AS coherence: routing a structure to the
  identity heap because per-child COW divergence broke a *correct* OpenZFS) ->
  the fork follow-on stack (post #1455/56/57). These are "fork must not break a
  correct subsystem," not "OpenZFS is wrong."
- **Intersection** (the ZFS-write-across-fork walls): decide per fix. If the fix
  makes OpenZFS-on-OSv work AT ALL (even single-process), it's #1423. If it only
  matters because a forked PG backend has a private COW copy of ZFS state, it's
  the fork stack. When in doubt, split the commit so each part lands where it
  belongs.
Keep conf_zfs=openzfs everywhere for PG. bsd_zfs is legacy; not the PG target.

## STANDING MANDATE (user, 2026-07-27): persist until DONE
GOAL: a stable, functional, PRODUCTION-grade OSv+PostgreSQL on EC2 over ZFS
(eventually Crucible), benchmarked at PARITY-OR-FASTER vs Linux+PG.
- Fix EVERY issue on the ZFS/PG path, not "one more attempt" -- CONTINUE until
  OSv+PG is qualified (survives sustained write at default recordsize=8k,
  reboot-clean, KVM+Firecracker) AND the HammerDB + pgbench matrices run at
  parity-or-faster vs the banked Linux baselines.
- EC2 burn is AUTHORIZED for this purpose (metal as needed). Still: terminate
  idle boxes, delete EBS when done, don't leave stray resources.
- Operating pattern (established): each diagnostic/fix agent narrows the bug +
  may land a fix, then hits its tool budget. RESUME with accumulated evidence
  (the corruptor*.txt reports) rather than restarting cold. Keep a running
  "ruled-out" list so no attempt repeats prior work. Watch elapsed-vs-tool-count
  to catch wedges early; reap zombie qemus.
- HONESTY gate stays: no "qualified" without pasted default-8k survival; no
  "parity" without a real A/B table; no fix claimed without validation (the
  spurious entropy-ring "fix" in attempt-2 is why).
- Current open bug: SMP-race wild-write corrupting ZFS METADATA / PT pages in
  the identity heap, ~128KiB-aligned runs, at recordsize=8k under -smp>=2 +
  sustained write. Next technique: metadata/PT-page CANARY -> stable victim ->
  KVM hardware watchpoint -> writer PC. LAYOUT-NEUTRAL only.

## HUGE PAGES: test both states in qualify AND benchmark (user, 2026-07-27)
- Qualify + bench BOTH with huge pages ENABLED and DISABLED, on OSv and Linux.
- Diagnostic relevance to the current corruptor: it corrupts ZFS metadata /
  PAGE-TABLE pages in the identity heap in ~128KiB-aligned runs. Huge pages
  change PT structure (2MB mappings) + large-alloc backing, so hugepages on vs
  off may make the corruptor behave DIFFERENTLY (reproduce one, mask the other,
  or shift the aligned unit) -- a useful signal for naming the writer. So the
  qualify repro/validation must cover BOTH hugepage states, not just one.
- Qualify battery (pgbench -i -s1000 + -c16 -T120 + concurrent catalog + fork
  churn, reboot-clean, KVM+FC) x recordsize{4k,8k,16k,32k,64k,128k} x
  hugepages{on,off}. A fix must hold in BOTH hugepage states at default 8k.
- Benchmark: hugepages{on,off} is already a matrix axis; keep it for OSv+Linux.
