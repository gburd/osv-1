# io_uring Implementation Status

## Overview

OSv includes a partial implementation of Linux's io_uring async I/O interface located in `fs/io_uring.cc`. The implementation provides the core syscalls and basic structure but has limitations that prevent full userspace ring buffer access.

## What Works

### Syscalls
- ✅ `io_uring_setup()` - Full parameter validation; populates `sq_off`/`cq_off` for liburing ABI compatibility; rejects unsupported flags (SQPOLL, SQ_AFF) with EINVAL
- ✅ `io_uring_enter()` - Submission/completion syscall interface; returns submitted count per Linux ABI
- ✅ `io_uring_register()` - Buffer and file registration (REGISTER/UNREGISTER_BUFFERS, REGISTER/UNREGISTER_FILES)

### Supported Operations
- ✅ `IORING_OP_NOP` - No-operation (for testing)
- ✅ `IORING_OP_READ` - Single buffer read
- ✅ `IORING_OP_READV` - Vectored read
- ✅ `IORING_OP_WRITE` - Single buffer write
- ✅ `IORING_OP_WRITEV` - Vectored write
- ✅ `IORING_OP_FSYNC` - File synchronization

### Core Infrastructure
- ✅ Ring buffer data structures (submission/completion queues)
- ✅ Thread-based async execution model
- ✅ Completion notification via CQEs
- ✅ Basic file descriptor management
- ✅ **mmap support for all three regions (SQ ring, CQ ring, SQE array)**
- ✅ **Userspace ring buffer access**
- ✅ **Shared memory synchronization with atomic operations**

## Implementation Details

### Memory Mapping

The io_uring implementation now properly shares memory between kernel and userspace using three mmap regions:

1. **SQ Ring (offset 0x0)**: Contains submission queue metadata and index array
   - head, tail, mask, entries, flags, dropped
   - Index array mapping SQ positions to SQE indices

2. **CQ Ring (offset 0x8000000)**: Contains completion queue metadata and CQE array
   - head, tail, mask, entries, overflow
   - Embedded CQE array

3. **SQE Array (offset 0x10000000)**: Submission queue entries
   - Direct array of SQEs
   - Shared between kernel and userspace

### Synchronization

The implementation uses atomic operations for proper ring synchronization:
- `__atomic_load_n(..., __ATOMIC_ACQUIRE)` for reading head/tail pointers
- `__atomic_store_n(..., __ATOMIC_RELEASE)` for updating head/tail pointers
- Memory fences to ensure CQE data is visible before tail updates

### Page Mapping

The `map_page()` implementation:
- Determines which region (SQ, CQ, or SQE) based on offset
- Uses `virt_to_phys()` to get physical addresses
- Creates leaf PTEs with `make_leaf_pte()`
- Maps kernel memory directly to userspace virtual addresses

## Testing Status

Tests in `tests/tst-io_uring.cc` verify:
- ✅ Syscall interface works correctly
- ✅ Parameter validation functions properly
- ✅ Ring initialization succeeds
- ✅ Error handling is correct
- ✅ Multiple rings can coexist
- ✅ **mmap of all three regions succeeds**
- ✅ **SQE array is writable from userspace**
- ✅ **Ring metadata is readable/writable**
- ✅ **NOP operations via ring buffers**
- ✅ **File read/write via ring buffers**

The test suite now includes:
- `test_io_uring_mmap_access()` - Verifies SQE array and ring metadata access
- `test_io_uring_nop_via_ring()` - Tests NOP submission via ring tail update
- `test_io_uring_file_io()` - Tests actual file I/O operations through rings

## Remaining Work

### 1. Additional Operations

Additional operations to consider:
- `IORING_OP_READ_FIXED` / `IORING_OP_WRITE_FIXED` (registered buffers)
- `IORING_OP_POLL_ADD` / `IORING_OP_POLL_REMOVE` (polling)
- `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` (network I/O)
- `IORING_OP_TIMEOUT` (timeouts)
- `IORING_OP_ACCEPT` / `IORING_OP_CONNECT` (async socket operations)

### 2. Implement io_uring_register

Replace stub with:
- `IORING_REGISTER_BUFFERS` - Register fixed buffers
- `IORING_REGISTER_FILES` - Register file descriptors
- `IORING_UNREGISTER_BUFFERS` / `IORING_UNREGISTER_FILES`
- `IORING_REGISTER_EVENTFD` - Register eventfd for notifications

### 3. Performance Optimizations

Current implementation uses thread-per-operation model. Future optimizations:
- Thread pool for worker threads
- Inline execution for simple operations
- Better integration with bio layer
- Batch processing of multiple SQEs

### 4. Advanced Features

Features from newer io_uring versions:
- `IORING_SETUP_SQPOLL` - Kernel-side submission polling
- `IORING_SETUP_IOPOLL` - Busy-wait for completions
- Linked operations (IOSQE_IO_LINK)
- Operation chains and dependencies

## Architecture Notes

### Current Design
- **Thread-per-operation**: Each SQE spawns a detached thread
- **Simple**: Easy to understand and debug
- **Not optimal**: High thread overhead for many small operations

### Alternative Approaches
1. **Thread pool**: Pre-allocated worker threads
2. **Inline execution**: Some operations could execute synchronously
3. **Bio integration**: Better integration with OSv's bio layer

## Performance Expectations

Once complete, io_uring should provide:
- **30-50% improvement** over traditional I/O for high-depth async workloads
- **Lower CPU usage** via batch submission/completion
- **Better scalability** for parallel I/O operations

## Compatibility

The implementation follows Linux io_uring ABI:
- Structure layouts match Linux kernel definitions
- Syscall numbers compatible with Linux
- Should work with liburing once mmap is fixed

## References

- Linux io_uring documentation: https://kernel.dk/io_uring.pdf
- OSv implementation: `fs/io_uring.cc`, `include/osv/io_uring.h`
- Tests: `tests/tst-io_uring.cc`

## Summary

**Status**: Core implementation complete and functional

**What's Working**:
- Full mmap support for all three ring regions (SQ, CQ, SQE array)
- Userspace can submit operations via ring buffers
- Userspace can read completions via CQE array
- Proper synchronization with atomic operations
- File I/O operations (read, write, fsync)
- Basic operations (NOP)

**What's Next**:
1. Add more operation types (network I/O, polling, etc.)
2. ~~Implement io_uring_register functionality~~ (done: buffers and files)
3. Performance optimizations (thread pool, inline execution)
4. Advanced features (IOPOLL, linked operations; SQPOLL intentionally not supported)

**Compatibility**: The implementation follows Linux io_uring ABI and should work with applications using the standard io_uring interface once additional operations are added.

---

**Last Updated**: April 2026
**Implementation by**: OSv Developers

## Changes Made

### April 2026 - Complete mmap Implementation

**Problem**: The original implementation allocated ring memory but returned `nullptr` from the `mmap()` function, preventing userspace from accessing the SQE array and ring buffers.

**Solution**:
1. **Proper VMA Creation**: Modified `io_uring_file::mmap()` to return `mmu::default_file_vma()` instead of nullptr
2. **Page Mapping**: Implemented `map_page()` to translate offsets to physical pages:
   - Determines region (SQ, CQ, or SQE) from mmap offset
   - Uses `virt_to_phys()` to get physical addresses of kernel memory
   - Creates leaf PTEs to map kernel pages to userspace
3. **Shared Memory Allocation**: All three regions now use `mmu::map_anon()` for proper shared memory:
   - SQ ring with embedded index array
   - CQ ring with embedded CQE array
   - SQE array (converted from `new[]` to `map_anon()`)
4. **Atomic Synchronization**: Updated submission/completion functions:
   - Read head/tail from shared memory with `__ATOMIC_ACQUIRE`
   - Write head/tail with `__ATOMIC_RELEASE`
   - Memory fences ensure proper ordering

**Files Modified**:
- `/home/gburd/ws/osv/fs/io_uring.cc` - Main implementation
- `/home/gburd/ws/osv/tests/tst-io_uring.cc` - Added comprehensive tests
- `/home/gburd/ws/osv/docs/io_uring-status.md` - Updated documentation

**Testing**:
- Added `test_io_uring_mmap_access()` - Verifies SQE array is writable
- Added `test_io_uring_nop_via_ring()` - Tests ring submission
- Added `test_io_uring_file_io()` - Tests actual file I/O through rings
