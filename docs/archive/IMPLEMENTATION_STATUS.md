# OSv Feature Implementation Status

## Summary

This document tracks the implementation of 5 features for OSv as per the plan.

### Completion Status

| Task | Status | Notes |
|------|--------|-------|
| 1. Remove Rust stubs | ✅ Complete | Committed: 72100890 |
| 2. OpenZFS 2.3.6 integration | ⚠️ 80% Complete | Committed: e077485f |
| 3. Test TRIM/DISCARD | ⏳ Blocked by Task 2 | Waiting for OpenZFS build |
| 4. Multiqueue testing | ⏳ Not Started | Independent task |
| 5. io_uring completion | ⏳ Not Started | Independent task |

---

## Task 1: Remove Rust Stubs ✅

### What Was Done
- Deleted `rust/rust/crucible-osv/` and `rust/rust/osv-sys/` directories
- Updated `rust/rust/Cargo.toml` to remove workspace members
- Updated `drivers/crucible-blk.cc` header to clarify C++ implementation
- Updated `FEATURE_STATUS.md` to note pure C++ implementation
- Rewrote `RUST_CODE_EXPLANATION.md` with removal notice

### Verification
```bash
# No Crucible Rust files remain
find /home/gburd/ws/osv -name "*.rs" 2>/dev/null | grep -v apps
# Returns: No crucible-osv or osv-sys files

# C++ driver header shows pure C++ implementation
head -15 drivers/crucible-blk.cc
```

### Commit
- `72100890` - Remove unused Rust stubs from Crucible driver

---

## Task 2: OpenZFS 2.3.6 Integration ⚠️

### What Was Done

#### OpenZFS Submodule ✅
- Submodule at `external/openzfs` initialized to zfs-2.3.6 (commit c840612ee)
- Applied OSv platform patches (7,186 lines):
  - `0001-OSv-Add-complete-platform-layer-with-SPL-for-OpenZFS.patch` (5,795 lines)
  - `0002-feat-zfs-Add-OSv-OS-layer-implementation-with-auto-u.patch` (1,391 lines)
- Platform files verified present (52 headers, 24 implementation files)

#### Makefile Updates ✅
- Added `drivers/blk-mq.o` for multiqueue support
- Added `fs/io_uring.o` for io_uring support
- Replaced Rust Crucible with C++ Crucible driver files:
  - `drivers/crucible-connection.o`
  - `drivers/crucible-request.o`
  - `drivers/crucible-hash.o`
  - `drivers/crucible-client.o`
  - `drivers/crucible-blk.o`
- Removed Rust build system for Crucible
- Added `tests/tst-io_uring.so` to tools

#### Files Added ✅
- `patches/openzfs/` - OpenZFS patches and README
- `scripts/apply-openzfs-patches.sh` - Patch application script
- `bsd/sys/cddl/openzfs_sources.mk` - OpenZFS source file list (~376 files)
- `bsd/sys/cddl/OPENZFS_MAPPING.md` - Documentation
- `bsd/sys/cddl/compat/opensolaris/openzfs_osv_compat.c` - Compatibility layer
- `bsd/sys/cddl/osv-patches/` - Integration documentation

### What Remains ⚠️

#### Critical - Build System Integration
The Makefile still references old BSD-ZFS sources. Need to:

1. **Include openzfs_sources.mk** in Makefile:
   ```make
   # Around line 860, replace old zfs variable with:
   include bsd/sys/cddl/openzfs_sources.mk
   ```

2. **Remove BSD-ZFS source references**:
   - Lines 746-860: Old `solaris +=` and `zfs +=` variables
   - These should be replaced by openzfs_sources.mk variables

3. **Update libsolaris.so build**:
   - Line 2457-2483: `libsolaris-objects` still uses old BSD-ZFS paths
   - Should use OpenZFS sources from openzfs_sources.mk

4. **loader.cc updates**:
   - Check if initialization code needs updates for OpenZFS
   - Verify libsolaris.so loading works with new OpenZFS

#### How to Complete

**Option A: Manual merge (recommended for safety)**
```bash
# Check feat/openzfs Makefile for the exact integration
git show feat/openzfs:Makefile > /tmp/feat-openzfs-makefile.txt
# Compare with current and manually integrate OpenZFS build rules
diff -u Makefile /tmp/feat-openzfs-makefile.txt | less
```

**Option B: Accept feat/openzfs Makefile and re-add our changes**
```bash
# Get complete Makefile from feat/openzfs
git checkout feat/openzfs -- Makefile

# Re-apply our changes:
# 1. Add blk-mq.o
# 2. Add io_uring.o
# 3. Add C++ Crucible drivers
# 4. Add tst-io_uring.so
# 5. Remove Rust Crucible build section
```

**Option C: Use the included openzfs_sources.mk**
```bash
# Edit Makefile around line 860:
# Replace:
#   solaris += bsd/sys/cddl/contrib/...
#   zfs += bsd/sys/cddl/contrib/...
# With:
#   include bsd/sys/cddl/openzfs_sources.mk
#   solaris += $(openzfs_common)
#   zfs += $(openzfs_module)
```

### Verification Steps

Once build integration is complete:

```bash
# 1. Build with OpenZFS
make clean && make fs=zfs -j$(nproc)

# 2. Check that OpenZFS files are compiled (not BSD-ZFS)
ls build/release.x64/external/openzfs/ | head

# 3. Verify libsolaris.so exists and has correct symbols
nm build/release.x64/libsolaris.so | grep zfs | head

# 4. Test basic pool operations
./scripts/run.py -e "zpool create testpool /dev/vblk0 && zpool status"
```

### Commit
- `e077485f` - WIP: Integrate OpenZFS 2.3.6 with io_uring and C++ Crucible

---

## Task 3: Test TRIM/DISCARD with OpenZFS ⏳

### Status
**Blocked by Task 2** - Cannot test until OpenZFS builds successfully.

### Plan
Once Task 2 is complete:

1. Research OpenZFS 2.3.6 TRIM support:
   - Check if `autotrim` property exists
   - Check if `zpool trim` command works
   - Verify DISCARD integration with VirtIO-BLK

2. Create test script `apps/zfs-trim-test/test.sh`:
   ```bash
   #!/bin/bash
   # Create pool with autotrim
   zpool create -o autotrim=on trimpool /dev/vblk0

   # Write and delete data
   dd if=/dev/urandom of=/trimpool/testfile bs=1M count=100
   rm /trimpool/testfile
   sync

   # Manual trim
   zpool trim trimpool
   ```

3. Test with QEMU DISCARD:
   ```bash
   # Update scripts/run.py to add discard=unmap to drive options
   ./scripts/run.py -e "bash /apps/zfs-trim-test/test.sh"
   ```

4. Document results in `docs/zfs-trim-discard.md`

---

## Task 4: Test VirtIO-BLK Multiqueue ⏳

### Status
**Not Started** - Independent of other tasks.

### Plan

1. **Add QEMU option** in `scripts/run.py`:
   ```python
   parser.add_argument("--virtio-blk-queues",
                       type=int,
                       default=1,
                       help="VirtIO-BLK queue count")

   # In device string:
   device_str = "virtio-blk-pci,id=blk0,drive=hd0"
   if cmdargs.virtio_blk_queues > 1:
       device_str += f",num-queues={cmdargs.virtio_blk_queues}"
   ```

2. **Add TODO comment** in `drivers/virtio-blk.cc` (line 311):
   ```cpp
   // TODO: Implement per-CPU queue assignment for multiqueue I/O
   // Currently all requests use queue 0, even when multiple queues available
   auto* queue = get_virt_queue(0);
   ```

3. **Test**:
   ```bash
   ./scripts/run.py --virtio-blk-queues 4
   # Check kernel log for "virtio-blk: multiqueue with 4 queues"
   ```

4. **Update documentation**:
   ```markdown
   ### Multiqueue I/O
   - QEMU configuration: ✅ Implemented
   - Queue detection: ✅ Working
   - Queue utilization: ❌ Not implemented (all I/O uses queue 0)
   ```

---

## Task 5: Complete io_uring Implementation ⏳

### Status
**Not Started** - Independent of other tasks.

### Current State
- Basic io_uring implementation exists in `fs/io_uring.cc`
- Test exists in `tests/tst-io_uring.cc`
- Makefile updated to include `fs/io_uring.o` ✅

### Missing Features

#### 1. Large Page Support
Add `hw_ptep<1>` overloads in `fs/io_uring.cc`:

```cpp
bool io_uring_file::map_page(uintptr_t offset, mmu::hw_ptep<1> ptep,
                              mmu::pt_element<1> pte, bool write, bool shared)
{
    // Large page (2MB) mapping implementation
    // Similar to 4KB version but uses hw_ptep<1>
}

bool io_uring_file::put_page(void *addr, uintptr_t offset, mmu::hw_ptep<1> ptep)
{
    // Unmap large page
    ptep.write(mmu::pt_element<1>());
    return true;
}
```

#### 2. io_uring_register() Implementation
Currently returns ENOSYS. Implement at least:
- `IORING_REGISTER_BUFFERS` / `IORING_UNREGISTER_BUFFERS`
- `IORING_REGISTER_FILES` / `IORING_UNREGISTER_FILES`

Add to io_uring_context:
```cpp
struct io_uring_context {
    // ... existing fields ...
    void **registered_buffers;
    unsigned nr_registered_buffers;
    struct file **registered_files;
    unsigned nr_registered_files;
};
```

#### 3. Demo Application
Create `apps/io-uring-demo/` with simple async file copy example.

#### 4. Fix Test Comment
Update `tests/tst-io_uring.cc` lines 47-51:
```cpp
/* Note: mmap implementation is COMPLETE and functional.
 * All three regions (SQ ring, CQ ring, SQE array) are properly mapped.
 * Known limitations:
 * - Large page (2MB) support added but not fully tested
 * - io_uring_register() implemented for buffers and files
 * - Thread-per-op model (not thread pool) - acceptable for now
 */
```

---

## Current Build Status

### What Builds ✅
- Core kernel
- C++ Crucible driver
- io_uring (added to build)
- Multiqueue infrastructure (blk-mq.o added)
- BSD-ZFS (old, still active)

### What Doesn't Build ❌
- OpenZFS 2.3.6 (not integrated into Makefile yet)
- ZFS filesystem layer (libsolaris.so fails due to missing sources)

### How to Fix Build
Complete Task 2 remaining work (see above).

---

## Testing Prerequisites

### For Local Testing
```bash
# Once OpenZFS integration is complete:
make clean && make fs=zfs -j$(nproc)

# Basic ZFS test:
./scripts/run.py -e "zpool create testpool /dev/vblk0 && zpool status"
```

### For Full Feature Testing
1. **Complete Task 2** - OpenZFS must build
2. **Test TRIM** (Task 3) - Requires OpenZFS working
3. **Test Multiqueue** (Task 4) - Independent, can do anytime
4. **Test io_uring** (Task 5) - Independent, can do anytime

---

## Next Steps

### Immediate (Critical)
1. Complete OpenZFS Makefile integration (Task 2 remaining work)
2. Verify build succeeds with `make fs=zfs`
3. Test basic ZFS operations

### Short Term
4. Implement multiqueue testing (Task 4) - Quick win
5. Fix io_uring test comment and add large page support (Task 5)
6. Test TRIM/DISCARD (Task 3)

### Optional Enhancements
7. Implement io_uring_register() fully
8. Create io_uring demo application
9. Add comprehensive ZFS testing

---

## Files Modified

### Committed Changes
- `drivers/crucible-blk.cc` - Header documentation
- `FEATURE_STATUS.md` - Updated Crucible section
- `RUST_CODE_EXPLANATION.md` - Rewritten for removal
- `rust/rust/Cargo.toml` - Removed workspace members
- `rust/rust/crucible-osv/` - Deleted (4 files)
- `rust/rust/osv-sys/` - Deleted (5 files)
- `.gitmodules` - Updated OpenZFS submodule config
- `Makefile` - Added io_uring, blk-mq, C++ Crucible; removed Rust Crucible
- `patches/openzfs/` - Added (3 files)
- `scripts/apply-openzfs-patches.sh` - Added
- `bsd/sys/cddl/` - Added OpenZFS integration files (7 files)

### Modified Submodule
- `external/openzfs` - Patches applied, at commit bb1196820

---

## Known Issues

1. **Build currently fails** - libsolaris.so missing because Makefile still uses BSD-ZFS sources
2. **OpenZFS not active** - Despite patches being applied, old BSD-ZFS is still being built
3. **loader.cc conflicts** - May need updates for OpenZFS initialization

---

## References

- Plan document: See conversation history
- OpenZFS patches: `patches/openzfs/README.md`
- Integration guide: `bsd/sys/cddl/osv-patches/INTEGRATION.md`
- feat/openzfs branch: Original OpenZFS integration work
