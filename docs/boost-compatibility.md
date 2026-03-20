# Boost Compatibility Notes

## Issue Summary

OSv's build system expects `libboost_system.a` to be present as a compiled static library. However, starting with Boost 1.66, `boost::system` became a header-only library, and `libboost_system.a` is no longer provided.

## Version Compatibility

| Boost Version | libboost_system.a | OSv Compatibility | Notes |
|---------------|-------------------|-------------------|-------|
| 1.55 - 1.65   | ✅ Compiled lib   | ✅ Fully compatible | Historically used by OSv |
| 1.66 - 1.76   | ⚠️ Empty stub     | ⚠️ Works with warnings | Transitional period |
| 1.77          | ✅ Compiled lib   | ✅ Fully compatible | Last version with compiled lib |
| 1.78 - 1.81   | ❌ Header-only    | ❌ Requires Makefile changes | Need dummy library or Makefile fix |
| 1.82+         | ❌ Header-only    | ❌ Requires Makefile changes + C++14 | Additional C++ standard requirements |

## Current Solution (Nix Flake)

The Nix flake (`flake.nix`) uses Boost 1.77:

```nix
boostStatic = pkgs.boost177.override {
  enableStatic = true;
  enableShared = false;
};
```

This provides `libboost_system.a` as expected by OSv's Makefile.

## Makefile Detection Logic

Located at lines 2053-2088 in `/home/gburd/ws/osv/Makefile`:

```makefile
# Link with -mt if present, else the base version
boost-mt := -mt
boost-lib-dir := $(dir $(shell $(CC) --print-file-name libboost_system$(boost-mt).a))
ifeq ($(filter /%,$(boost-lib-dir)),)
    boost-mt :=
    boost-lib-dir := $(dir $(shell $(CC) --print-file-name libboost_system$(boost-mt).a))
endif

# ... (later)
boost-libs := $(boost-lib-dir)/libboost_system$(boost-mt).a
```

The Makefile searches for `libboost_system.a` or `libboost_system-mt.a` and fails if neither is found.

## Linker Usage

The Boost library is linked at lines 2137 and 2146:

```makefile
linker_archives_options = --no-whole-archive $(libstdc++.a) $(libgcc.a) $(libgcc_eh.a) $(boost-libs) \
  --exclude-libs libstdc++.a --gc-sections

# Or:
linker_archives_options = --whole-archive $(libstdc++.a) $(libgcc_eh.a) $(boost-libs) --no-whole-archive $(libgcc.a)
```

## Why Does OSv Need Boost?

OSv uses Boost for:

1. **boost::lockfree** - Lock-free data structures (e.g., `drivers/virtio-blk.cc`)
2. **boost::intrusive** - Intrusive containers
3. **boost::system** - Error code system (now header-only)

### Actual boost::system Usage

Searching the codebase:

```bash
$ grep -r "boost::system" --include="*.cc" --include="*.hh"
# Result: Minimal usage, mostly for error codes
```

Most actual usage is **header-only** even in older Boost versions. The compiled library was primarily for backward ABI compatibility.

## Future Fix: Update Makefile

To support modern Boost (1.81+), update the Makefile:

### Option 1: Conditional Library Linking

```makefile
# Detect if libboost_system.a exists
BOOST_SYSTEM_LIB := $(shell $(CC) --print-file-name=libboost_system.a)
ifeq ($(filter /%,$(BOOST_SYSTEM_LIB)),)
    # Header-only boost (1.81+), no library needed
    boost-libs :=
else
    # Compiled boost_system available
    boost-libs := $(BOOST_SYSTEM_LIB)
endif
```

### Option 2: Version Detection

```makefile
# Detect Boost version from headers
BOOST_VERSION := $(shell echo '\#include <boost/version.hpp>' | \
    $(CXX) -x c++ -E - | grep 'define BOOST_VERSION' | cut -d' ' -f3)

# If Boost >= 1.66.0 (version 106600), skip boost_system library
ifeq ($(shell test $(BOOST_VERSION) -ge 106600 && echo yes),yes)
    boost-libs :=
else
    boost-libs := $(boost-lib-dir)/libboost_system$(boost-mt).a
endif
```

## Workaround for Boost 1.81+ (Without Makefile Changes)

Create a dummy `libboost_system.a`:

```bash
echo "void __boost_system_dummy() {}" > boost_dummy.c
gcc -c boost_dummy.c -o boost_dummy.o
ar rcs libboost_system.a boost_dummy.o
sudo cp libboost_system.a /usr/lib/
```

This was used temporarily in the Nix flake but is not a clean solution.

## Testing Different Boost Versions

### With Nix

```bash
# Test Boost 1.77
nix develop  # Uses flake.nix configuration
./scripts/build

# Test Boost 1.55 (older)
# Edit flake.nix: boost177 -> boost155
nix develop
./scripts/build
```

### With System Packages

```bash
# Ubuntu 20.04 (Boost 1.71)
sudo apt install libboost-all-dev
./scripts/build

# Ubuntu 22.04 (Boost 1.74)
sudo apt install libboost-all-dev
./scripts/build

# Fedora 39 (Boost 1.81 - requires Makefile fix)
sudo dnf install boost-static
# Build will fail without Makefile changes
```

## Recommended Action

**Short term**: Use Boost 1.77 (current Nix flake configuration)

**Medium term**: Update Makefile to support both old and new Boost versions

**Long term**: Remove boost::system dependency entirely if possible

## Impact on OSv Users

### Developers Using Nix
✅ No action needed - flake provides Boost 1.77

### Developers on Ubuntu/Debian
✅ System Boost (1.65-1.77) works out of box

### Developers on Fedora 39+
❌ Need Makefile fix or Boost downgrade

### CI/CD Pipelines
⚠️ Pin Boost version or update Makefile

## Related Files

- `/home/gburd/ws/osv/Makefile` - Lines 2053-2088 (detection), 2137, 2146 (linking)
- `/home/gburd/ws/osv/flake.nix` - Nix Boost configuration
- `/home/gburd/ws/osv/scripts/setup.py` - Manual setup script

## References

- [Boost 1.66 Release Notes](https://www.boost.org/users/history/version_1_66_0.html) - "Boost.System is now header-only"
- [Boost 1.77 Documentation](https://www.boost.org/doc/libs/1_77_0/)
- [OSv Issue Tracker](https://github.com/cloudius-systems/osv/issues) - Search for "boost"

## Follow-Up Task

**Task**: Update OSv Makefile to support Boost 1.81+

**Priority**: Medium (not blocking current work)

**Effort**: ~2 hours (Makefile changes + testing)

**Files**:
- Modify: `/home/gburd/ws/osv/Makefile`
- Test on: Ubuntu 22.04, Fedora 39, NixOS

**Success Criteria**:
- Build succeeds with Boost 1.55 (old)
- Build succeeds with Boost 1.77 (current)
- Build succeeds with Boost 1.81+ (modern)
- No dummy libraries needed
