# REMOVED: Rust Stubs Have Been Deleted

## Summary

The Crucible driver is implemented **entirely in C++**, including a custom C++ implementation of Rust's bincode serialization format.

Previous Rust stubs (in `rust/rust/crucible-osv/` and `rust/rust/osv-sys/`) were never compiled or linked, and have been removed to avoid confusion.

---

## Actual Implementation

See `drivers/crucible-*.cc` for the real implementation (~48KB across 5 files):

| File | Purpose |
|------|---------|
| `crucible-blk.cc/hh` | Block device interface, bio handling |
| `crucible-client.cc/hh` | Upstairs client, quorum logic, pipelining |
| `crucible-connection.cc/hh` | TCP connection management |
| `crucible-request.cc/hh` | Request tracking and correlation |
| `crucible-messages.hh` | Protocol v13 message definitions |
| `crucible-bincode.hh` | **C++ bincode serialization** |
| `crucible-hash.cc/hh` | xxHash64 for integrity verification |
| `crucible-types.hh` | UUID, Result<T>, Optional<T> types |

---

## Why C++ Instead of Rust?

**Advantages:**
- Direct OSv kernel integration (no FFI boundary)
- Simpler build system (no Rust toolchain needed)
- Standard C++ debuggers work
- No kernel-mode Rust constraints (`no_std`, panic handler, allocator)

**Cost:**
- Had to implement bincode serialization in C++ (~200 lines in `crucible-bincode.hh`)
- This turned out to be straightforward and works perfectly

---

## Bincode Implementation

The C++ bincode implementation handles:
- Primitive types (u8, u16, u32, u64, i32, i64)
- Strings (length-prefixed)
- Byte arrays
- Optional values (Rust's `Option<T>`)
- UUIDs (16-byte arrays)
- Complex nested structures

This allows OSv to speak the Crucible protocol (which is bincode-based) without any Rust dependencies.

---

## Verification

Check what's actually linked:
```bash
nm build/release.x64/loader.elf | grep crucible | head
# Shows C++ symbols like:
#   UpsairsClient::write_sync
#   BincodeWriter::write_u64
```

No Rust code in the build:
```bash
grep -r "crucible.*\.rs" Makefile
# Returns nothing
```

---

## Conclusion

The Crucible driver is **pure C++**. Previous Rust stubs were historical artifacts from an earlier plan and have been removed.

For implementation details, see:
- `drivers/crucible-blk.cc` (main driver)
- `drivers/crucible-bincode.hh` (C++ bincode serialization)
- `FEATURE_STATUS.md` (feature documentation)
