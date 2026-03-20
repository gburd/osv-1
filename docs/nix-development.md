# Nix Development Environment for OSv

## Overview

OSv provides a reproducible development environment using Nix flakes. This ensures all developers have identical build dependencies regardless of their host system.

## Quick Start

```bash
# Enter development shell
nix develop

# Build OSv
./scripts/build

# Run OSv
./scripts/run.py
```

## Cross-Compilation

OSv supports cross-compilation between x86_64 and aarch64 architectures through dedicated Nix development shells.

### x86_64 → aarch64

Build for aarch64 from an x86_64 host:

```bash
# Enter cross-compilation environment
nix develop .#crossAarch64

# Build for aarch64
./scripts/build arch=aarch64

# Test with QEMU
qemu-system-aarch64 -M virt -cpu cortex-a57 -m 2G \
  -kernel build/release.aarch64/loader.elf \
  -append "--console=serial" -nographic
```

### aarch64 → x86_64

Build for x86_64 from an aarch64 host:

```bash
# Enter cross-compilation environment
nix develop .#crossX86_64

# Build for x86_64
./scripts/build arch=x64

# Test with QEMU
qemu-system-x86_64 -m 2G \
  -kernel build/release.x64/loader.elf \
  -append "--console=serial" -nographic
```

### How Cross-Compilation Works

The cross-compilation shells provide:

1. **Cross-toolchain**: GCC and binutils for target architecture
2. **Target libraries**: Boost, OpenSSL, yaml-cpp, etc. compiled for target
3. **Environment variables**: `CROSS_PREFIX` and `ARCH` set automatically

The flake sets up:
- `CROSS_PREFIX=aarch64-linux-gnu-` for aarch64 targets
- `CROSS_PREFIX=x86_64-linux-gnu-` for x86_64 targets
- `ARCH` variable for OSv build system

### Verifying Cross-Compiled Binaries

Check the architecture of built binaries:

```bash
# For aarch64 build
file build/release.aarch64/loader.elf
# Should output: ARM aarch64, version 1 (SYSV), statically linked

# For x86_64 build
file build/release.x64/loader.elf
# Should output: x86-64, version 1 (SYSV), statically linked
```

### Troubleshooting Cross-Compilation

**Issue**: Cross-compilation fails with missing libraries

**Solution**: Ensure target architecture libraries are available in Nix cache:
```bash
nix develop .#crossAarch64 --command bash -c 'echo $boost_base'
# Should show path to aarch64 boost
```

**Issue**: QEMU doesn't boot cross-compiled kernel

**Solution**: Verify the binary architecture is correct:
```bash
file build/release.aarch64/loader.elf
readelf -h build/release.aarch64/loader.elf | grep Machine
```

## Using direnv (Recommended)

For automatic environment loading:

```bash
# Install direnv (if not already installed)
# On NixOS: already available
# On other systems: see https://direnv.net/

# Enable for this project
echo "use flake" > .envrc
direnv allow

# Environment automatically loads when entering directory
cd /path/to/osv  # Environment activates automatically
```

## What's Included

The Nix development shell provides:

### Core Build Tools
- GCC 15.2.0 (C/C++ compiler)
- GNU Make 4.4.1
- Python 3.13.12
- Autoconf, Automake, Libtool
- Bison, Flex (parser generators)
- Git

### Required Libraries
- **Boost 1.77** (with static libraries including libboost_system.a)
- libedit (command-line editing)
- OpenSSL 3.6 (cryptography)
- yaml-cpp (YAML parsing)
- Lua 5.4 (embedded scripting)

### Development Tools
- QEMU 10.2.1 (emulation)
- GDB 17.1 (debugging)
- genromfs (ROM filesystem creation)
- tcpdump (network analysis)
- pax-utils (ELF analysis)

### Java Toolchain
- OpenJDK 17 (for Java applications)
- Maven 3.9.12 (build automation)
- Apache Ant 1.10.15 (build tool)

### Python Packages
- dpkt (packet analysis)
- requests (HTTP library)

## Known Issues

### Boost Compatibility

**Issue**: OSv's Makefile expects `libboost_system.a`, which became header-only in Boost 1.66+.

**Current Solution**: flake.nix uses Boost 1.77, the last version with `libboost_system.a` as a compiled library.

**Future Work**: Update OSv's Makefile (lines 2053-2088) to detect Boost version and handle header-only boost_system for Boost >= 1.81.

See: `/home/gburd/ws/osv/docs/boost-compatibility.md`

### Lua Module Build

**Issue**: Default OSv build includes lua modules that fail on NixOS due to dynamic linking of luarocks.

**Workaround**: Build with alternative filesystem or disable lua modules:
```bash
./scripts/build fs=rofs  # Use ROFS instead of ZFS (skips lua)
```

**Status**: Not critical for ZFS/storage functionality. Lua is used for ZFS Channel Programs (advanced feature).

## Environment Variables

The Nix shell sets these variables:

- `OSV_ROOT`: Path to OSv repository root
- `boost_base`: Path to Boost installation (for Makefile)
- `PYTHONPATH`: Python package search paths

## Customization

### Adding Packages

Edit `flake.nix` and add packages to `nativeBuildInputs`:

```nix
nativeBuildInputs = with pkgs; [
  # ... existing packages ...
  your-package-here
];
```

Then update the lock file:
```bash
nix flake update
```

### Changing Boost Version

If you need a different Boost version:

```nix
# In flake.nix, modify:
boostStatic = pkgs.boost177.override {  # Change version here
  enableStatic = true;
  enableShared = false;
};
```

Available versions: `boost155`, `boost159`, `boost166`, `boost170`, `boost177`, `boost181`

## Debugging

### Check Package Versions

```bash
nix develop --command bash -c 'gcc --version && python3 --version && qemu-system-x86_64 --version'
```

### Verify Boost

```bash
nix develop --command bash -c 'echo $boost_base && ls -la $boost_base/lib/libboost_system.a'
```

### Clean Rebuild

```bash
# Exit any nix shells
exit

# Clean build artifacts
./scripts/build clean

# Re-enter and rebuild
nix develop
./scripts/build
```

## Comparison with Manual Setup

| Aspect | Nix Flake | Manual Setup |
|--------|-----------|--------------|
| Reproducibility | ✅ Guaranteed | ❌ System-dependent |
| Setup Time | ~5 min (first time) | ~15-30 min |
| Dependencies | Automatic | Manual via setup.py |
| Isolation | ✅ Per-project | ❌ System-wide |
| Multi-version | ✅ Easy | ❌ Difficult |
| Disk Space | Higher (Nix store) | Lower |

## Troubleshooting

### "error: experimental feature 'nix-command' is disabled"

Enable flakes in your Nix configuration:

```bash
# Add to ~/.config/nix/nix.conf or /etc/nix/nix.conf:
experimental-features = nix-command flakes
```

### "Package X not found"

The Nix cache might be outdated. Update:

```bash
nix flake update
```

### Build fails with "command not found"

Ensure you're in the Nix shell:

```bash
nix develop
# You should see "OSv development environment loaded"
```

## References

- [Nix Manual](https://nixos.org/manual/nix/stable/)
- [Nix Flakes](https://nixos.wiki/wiki/Flakes)
- [OSv Build System](https://github.com/cloudius-systems/osv/wiki)
- [Setup.py](../scripts/setup.py) - Manual setup alternative

## See Also

- [`docs/boost-compatibility.md`](boost-compatibility.md) - Boost version compatibility details
- [`flake.nix`](../flake.nix) - Nix flake configuration
- [`README.md`](../README.md#nixos--nix-flakes-recommended) - Main OSv documentation
