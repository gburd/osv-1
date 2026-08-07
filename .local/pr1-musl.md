# PR 1 - libc: upgrade musl from 1.1.24 to 1.2.1

**Branch:** `gburd/osv-1:pr/musl` -> `cloudius-systems/osv:master`
**Base:** stacks on PR 0 (`pr/build-compat`, fa343f2a). Two-commit branch:
fa343f2a (PR 0) + 9a41e781 (this).
**musl submodule:** ea9525c8 (1.1.24) -> 73cc775b (public musl v1.2.1 tag).
**Verified:** kernel + musl compile clean on GCC 14.3 / Boost 1.87
(`./scripts/build fs=zfs image=tests`, RC=0). In-tree libc-behavior tests
all PASS on the resulting image: tst-stdio (111 cases), tst-printf, tst-string,
tst-time (32; see note), tst-mmap (-c2), tst-pthread, tst-pthread-clock,
tst-strerror_r.

---

## Title

libc: upgrade musl from 1.1.24 to 1.2.1

## Body

Bump the bundled musl from 1.1.24 (2019) to 1.2.1 (2020), the last musl
release with the BSD-style internal layout that OSv's libc shim expects
before musl's 1.2.x source re-architecture. The upgrade picks up roughly
four years of upstream bug fixes in stdio, math, dns, and threading.

This depends on PR 0 (modern-toolchain compat): musl 1.2.1 cannot build
on GCC 14 / Boost 1.87 without it. I verified that the lower_bound /
conditional_t breakage PR 0 fixes is toolchain breakage, not musl's --
bare master fails identically on the same toolchain.

### Changes

- Repin the `musl_1.1.24` submodule to the public musl v1.2.1 tag
  (73cc775b).
- Add `-isystem musl/arch/$(musl_arch)` to the musl per-object include
  path: 1.2.x relocated several arch-specific headers there.
- `include/api/sys/__socket.h`: provide `struct msghdr` / `struct cmsghdr`
  (with correct big/little-endian padding) at the common path -- 1.2.x
  moved them out of the arch-specific `bits/socket.h`.
- `libc/stdio/__string_read.c`: add OSv's copy of `__string_read` and move
  it from the `musl` group to the `libc` group (it is now referenced from
  OSv-built stdio objects, not the musl tree).
- nftw(): silence a 1.2.1 `-Wmaybe-uninitialized` and initialise the field
  explicitly so results no longer depend on allocator state (the 1.1.24
  code relied on 1.1.x malloc zeroing).
- Suppress `-Wincompatible-pointer-types` on `tempnam`/`tmpnam`/`__map_file`
  (musl 1.2.x signatures vs OSv's `syscall_to_function.h` shim) -- ABI
  unchanged; these are OSv-shim build warnings only.
- Minor aarch64/x64 `bits/` header deltas (dirent `d_off`, socket type)
  to match 1.2.1.

### Notes

- No ABI break for OSv apps: the libc layout OSv exposes is unchanged;
  this is a within-1.x musl bump, deliberately stopping at 1.2.1 before
  the 1.2.x internal re-architecture.
- The in-tree libc tests are used as the musl unit-test bar. tst-time's
  TZ cases require a zoneinfo database in the image; on an FHS host this
  comes from `/usr/share/zoneinfo` and the tests pass. (On a non-FHS host
  the manifest glob can miss tzdata and those cases read UTC -- a
  packaging artifact, not a libc fault.)
- Second in the build/libc modernization series (PR 0 -> this -> virtio
  multi-queue -> ...).
