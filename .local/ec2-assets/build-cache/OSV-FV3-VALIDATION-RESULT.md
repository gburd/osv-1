# osv-fv3 VALIDATION RESULT (pin-and-validate, no bisect)

## STEP 1 — TOOLCHAIN/BOOT: SOLVED. The wall was NOT toolchain drift.
The real root cause of "native triple-fault / empty console / hang at 'Booting from Hard Disk'"
was building the AMI from `qemu-img convert -O raw usr.img`. That raw places the loader ELF at
~LBA 1186, but OSv's boot16 stub reads the loader from **LBA 128 (offset 0x10000)** -> it reads
ZEROS -> hang. FIX: register the AMI from `build/release.x64/bare.raw` (loader ELF is at LBA 128,
rofs appended). All three toolchains (fedora:38 gcc13.2.1, fedora:39 base gcc13.2.1,
fedora:39 pinned gcc13.3.1/ld2.40) boot the KERNEL fine via `-kernel loader.elf`; the toolchain
was a red herring. Winning pin (matches Aug-11): fedora:39 + gcc-13.3.1 + binutils-2.40.

PROOF (STEP 1): ami-0eb88fc1437501d00 (hello, bare.raw) on m5.xlarge Nitro i-0098b1c21972853ad:
  OSv v0.57.0-452-gde5d9b83 / eth0: 172.31.16.38 / Booted up in 157.97 ms / Cmdline: /hello / Hello from C code
Full recipe: NATIVE-BOOT-RECIPE.md in this dir.

## STEP 2 — DOES THE FORK FIX SERVE FORKED BACKENDS? NO. (0 successful; PG dies on first fork)
Built the full PG18-musl fork image on the fixed branch:
  branch fv3 = 34eca7799 (wip/native-fork-fix, v0.57.0-452, includes the COW-nested fix at
  core/mmu.cc:2498 "if (sched::exception_depth >= 2)") + cherry-picks c3c0bcde4 (nvme MSI-X cap)
  + 3437754eb (ena RSS), built conf_fork=1 (VERIFIED CONF_fork=1 in kernel_config.h),
  image=postgres18-musl fs=rofs. Native AMI ami-0909d9be904fe91fd on m5.xlarge Nitro
  i-01250241ce78e2bfd (also reproduced identically in QEMU TCG on the builder).

Console (native + TCG, identical):
  OSv v0.57.0-452 / eth0 up / Booted up 154 ms
  LOG: starting PostgreSQL 18.6 on x86_64-pc-linux-musl (gcc 13.3.1)
  LOG: listening on IPv4 address "0.0.0.0", port 5432
  LOG: database system is ready to accept connections        <- reaches READY
  page fault outside application, addr: 0x000000a100000000    <- then dies on first fork
  Assertion failed: sched::exception_depth <= 1 (core/sched.cc: reschedule_from_interrupt: 288)

pgbench/psql from the 2nd instance (172.31.16.234 -> PG 172.31.19.63:5432): connection TIMEOUT
on every attempt (PG postmaster is already dead before accepting). => 0 backends served.

### Why the fix does not cover this (evidence, not a bisect):
The fix (mmu.cc:2498) resolves a **COW write fault on a VALID vma** lock-free when nested. The
native/TCG crash is a **"page fault outside application" at an UNMAPPED address (0xa100000000)**
during the postmaster's first background-worker fork (checkpointer/bgwriter/walwriter/autovac).
That is a different fault class than the COW-write path the fix guards, so exception_depth still
climbs >=2 and reschedule_from_interrupt asserts. The fix is code-complete and boots, but it does
NOT prevent the postmaster-fork crash on this branch/base. NATIVE RO sweep: N/A (never served).

## Toolchain pin that boots the base native: fedora:39 + gcc-13.3.1 + binutils-2.40 (but the
## true unlock was bare.raw, not the pin). fix-serves-forked-backends-0-failed: NO. RO cells: N/A.
