# PR 0 — build: support modern toolchains (GCC 14, Boost 1.78+, C++14)

**Branch:** `gburd/osv-1:pr/build-compat` -> `cloudius-systems/osv:master`
**Commit:** fa343f2a (single commit, on top of master 8d2d4c89)
**Verified:** `./scripts/build fs=zfs image=empty` on GCC 14.3 + Boost 1.87 -> RC=0,
libsolaris.so linked, usr.img produced.

---

## Title

build: support modern toolchains (GCC 14, Boost 1.78+, C++14)

## Body

OSv's master branch does not build on current toolchains. Two independent
breakages compound:

- Boost 1.78+ made `boost::system` header-only, so `libboost_system.a` is
  no longer produced. The build hard-errors requiring it. Boost 1.87's
  lockfree headers additionally use `std::conditional_t`, which needs C++14.
- GCC 14 is stricter: `core/mmu.cc`'s four-argument `std::lower_bound` needs
  an explicit `<algorithm>` include, and Boost.Asio has removed the
  long-deprecated `io_service`, `resolver::query`, `mutable_buffers_1`, and
  `address_v4::from_string` APIs.

I verified that master (8d2d4c89) fails to compile in both C++ modes on
GCC 14.3 / Boost 1.87: `gnu++11` dies on Boost's `std::conditional_t`,
`gnu++14` dies on `core/mmu.cc` `lower_bound`.

### Changes

- Default `conf_cxx_level` to `gnu++14` (`conf/base.mk`, `modules/common.gmk`).
- Detect `libboost_system` only if present; never require it. Support both
  nixpkgs (`include/`) and FHS (`usr/include/`) Boost layouts.
- Add `<algorithm>` to `core/mmu.cc` and `core/pagecache.cc`.
- Port Boost.Asio call sites to `io_context`, range-returning
  `resolver::resolve`, `mutable_buffer`, and `make_address_v4`
  (`loader.cc`, `core/dhcp.cc`, `tools/cpiod`, `modules/httpserver-api`,
  `modules/cloud-init`, `modules/monitoring-agent`, `tests/*tcp*`).
- Replace `boost::math::isinf/isnan` with `std::isinf/isnan`.
- Detect OpenSSL 3.x (`libssl.so.3`) in addition to 1.1, and fall back to
  `LD_LIBRARY_PATH` when `ldconfig` is unavailable.

### Notes

- This is the first in a series modernizing OSv's build and bringing in
  musl 1.2.1, virtio-blk multi-queue, and OpenZFS 2.4.2. It is a prerequisite
  for the musl PR (musl 1.2.1 cannot build on GCC 14 without these fixes).
- No functional/runtime behavior change; this is purely build/compat.
- Relates to building on modern distros and NixOS, but contains nothing
  Nix-specific (the Nix dev-env lives outside this PR).
