# Building OSv on Nix / NixOS

OSv's build scripts assume a Filesystem Hierarchy Standard (FHS) layout:
headers under `/usr/include`, libraries under `/usr/lib`, and tools resolved
from a conventional `$PATH`. NixOS provides none of these by default, so the
build needs a few extra inputs and one explicit hint to find Boost.

This guide covers building the kernel and a ZFS image on NixOS. It assumes the
toolchain-compatibility fixes are present (GCC 14 / Boost 1.78+ / C++14); see
the build-compat changes that this document accompanies.

## Required packages

Enter a shell that provides the build tools the scripts shell out to:

```sh
nix-shell -p boost ncurses pkg-config flex bison
```

- `boost` — OSv links against Boost; the build auto-detects the nixpkgs
  `include/` layout (no `libboost_system.a` is required on Boost 1.78+).
- `ncurses` — needed by the kconfig menuconfig tooling.
- `pkg-config` — used to locate OpenSSL and other libraries.
- `flex` and `bison` — generate the kconfig lexer/parser. These are easy to
  miss: a fresh tree or a `scripts/build clean` deletes the generated
  `scripts/kconfig/*.c` files, so they must be regenerated on the next build.
  Without flex/bison the build fails early in the kconfig stage.

You also need GCC, `make`, and the usual prerequisites from the standard build
instructions; on NixOS supply them through your dev shell or `nix-shell -p`.

## Pointing the build at Boost

The build cannot guess the nixpkgs Boost store path, so pass it explicitly with
`boost_base`:

```sh
BOOST=$(nix-build '<nixpkgs>' -A boost.dev --no-out-link)
./scripts/build boost_base="$BOOST" image=native-example
```

`boost_base` should be the `-dev` output (the one containing `include/boost`).

## Building a ZFS image

```sh
nix-shell -p boost ncurses pkg-config flex bison --run "
  ./scripts/build fs=zfs fs_size_mb=4096 image=zfs-test \
    boost_base=$BOOST
"
```

If the host has no usable `javac` (the java-tests module probes for one), skip
the Java tests with `OSV_NO_JAVA_TESTS=1`, set both as an environment variable
and as a make variable:

```sh
OSV_NO_JAVA_TESTS=1 nix-shell -p boost ncurses pkg-config flex bison --run "
  OSV_NO_JAVA_TESTS=1 ./scripts/build fs=zfs image=zfs-test boost_base=$BOOST
"
```

## NixOS-specific runtime notes

- **Prebuilt host binaries (e.g. OpenJDK) carry `/nix/store` RUNPATHs.** When a
  module pulls a binary from the host into the image, its dynamic loader and
  RUNPATH point at `/nix/store` paths that do not exist inside OSv. Such modules
  must `patchelf` the binaries to OSv's in-image library paths.
- **`ldconfig` is unavailable.** OpenSSL detection falls back to scanning
  `LD_LIBRARY_PATH` when `ldconfig` is missing, and detects `libssl.so.3` in
  addition to 1.1.
- **Time-zone data lives at the nixpkgs store path, not `/usr/share/zoneinfo`.**
  Tests that hardcode the FHS zoneinfo path (such as `tst-time`) can report
  spurious failures; this is a packaging artifact, not a libc bug.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `flex: command not found` / `bison: command not found` early in build | kconfig sources were regenerated and the tools are absent | add `flex bison` to the nix-shell |
| Build cannot find Boost headers | nixpkgs Boost is not in `/usr/include` | pass `boost_base=<store path>/dev` |
| `javac` not found during image build | java-tests module probes for a JDK | set `OSV_NO_JAVA_TESTS=1` |
| Java/JVM binaries fail to start in guest | `/nix/store` RUNPATH baked into host binary | module must `patchelf` to in-image paths |
