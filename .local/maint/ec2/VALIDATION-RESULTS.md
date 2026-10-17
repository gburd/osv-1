# Validation results, OSv stub fixes + lwext4 0002 (2026-10-17)

Copyright (c) 2026 Greg Burd. BSD-3-Clause.

Host: Fedora 41 EC2 c7i.4xlarge (gcc 14.3, qemu 9.1, binutils 2.43), per the directive to
build on Fedora, not floki. Instance i-074e5e3db41607998. Earlier Fedora 44 (gcc 16) was
abandoned: too new for OSv (gcc-16 -Werror on pre-existing code, missing gold, strict ld on
tst-non-fpic, and an elf::object::relocate crash in cpiod during the ZFS manifest upload that
reproduced on BOTH gcc 14 and 16, so it is a ZFS-image/cpiod toolchain fragility, not a miscompile
nor our fixes). Switched to ramfs image to bypass the fragile ZFS cpiod upload path.

## Branches validated
- stubfixes (3 commits on master e16f1f45): nvme PRP assert, faccessat NOFOLLOW, pthread_cleanup.
- lwext4-0002 (on #1533 head, 4f06e228): lwext4 patch 0002.

## Results

### Kernel + test image build (stubfixes, fs=ramfs image=tests)
- Kernel compiles clean with gcc 14 and standard -Werror: 0 compile errors.
- Test image assembles: BUILD_RC=0.

### Runtime tests (scripts/run.py, headless)
- tst-faccessat.so: SUMMARY 22 tests, 0 failures. Includes the new AT_SYMLINK_NOFOLLOW cases
  (symlink to existing file, dangling symlink, plain file) that aborted the whole unikernel
  before the fix (UNIMPLEMENTED -> abort). GREEN.
- tst-pthread-cleanup.so: SUMMARY 6 tests, 0 failures. pop(1) runs the handler, pop(0) does not,
  nested handlers run LIFO. GREEN.
- Regression smoke (unchanged behavior expected): tst-pthread.so 10/0, tst-vfs.so "No errors
  detected", tst-threadcomplete.so Passed. No regression from the pthread or vfs changes.

### lwext4 0002 (the real patch-apply + compile test)
- modules/lwext4/Makefile applies BOTH patches via patch -p1 --forward: 0001 (ext4_extent.c,
  ext4_super.c) and 0002 (ext4_dir.h, ext4_fs.c Hunk #2 at 405 offset 1, ext4_mkfs.c). All clean,
  touch .patched. The build fails if any patch does not apply, so this is the gate.
- Patched source carries all three 0002 guards: ext4_dir.h:126 if (de == NULL); ext4_mkfs.c:151
  if (info->block_size == 0); ext4_fs.c two new return EIO bitmap guards (5 total, up from 3).
  0001 extent/superblock checks intact.
- Patched lwext4 compiles and links: liblwext4.so built (gcc 14, cmake 3.30).

## NVMe fix note
The nvme-queue.cc assert fix compiles into the kernel (part of the clean build above). Triggering
the 2 MiB-aligned PRP path at runtime needs ZFS vdev aggregation raised to 2 MiB (the audit showed
normal boot splits I/O below the ceiling and never reaches it), so there is no cheap unit test; the
fix is a corrected bound proven by arithmetic (worst-case unaligned 2 MiB = 513 pages =
prp_list_capacity) and a clean compile. The old assert panicked at exactly 512; the new bound
admits the real list capacity.

## Host workarounds used (NOT part of any committed change)
- OSV_NO_JAVA_TESTS path: neutralized api.require('java-tests') on the host (no JDK; test infra).
- tst-non-fpic.so dropped from the host test list (binutils 2.43 rejects its non-PIC relocations;
  pre-existing, unrelated to our fixes).
These are host-only build-environment accommodations; the committed branches are untouched.

## Verdict
All four fixes build and (where runtime-testable) pass on a trustworthy toolchain. Ready to open:
- nvme PRP assert: standalone PR on master.
- faccessat NOFOLLOW: standalone PR on master.
- pthread_cleanup: standalone PR on master.
- lwext4 0002: second commit on #1533 (pr/lwext4-cve).
