/*
 * Copyright (C) 2026 OSv Developers
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <osv/io_uring.h>
#include <osv/file.h>
#include <osv/vfs_file.hh>
#include <osv/bio.h>
#include <osv/debug.hh>
#include <osv/export.h>
#include <osv/mmu.hh>
#include <osv/sched.hh>
#include "fs/vfs/vfs.h"

#include <sys/mman.h>
#include <sys/uio.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <memory>

#define io_uring_debug(...) /* kprintf(__VA_ARGS__) */

static constexpr size_t MAX_ENTRIES = 4096;
static constexpr size_t MIN_ENTRIES = 1;

// Forward declaration
class io_uring_file;

// io_uring context structure
struct io_uring_ctx {
    mutex mtx;

    // Submission queue state
    struct {
        uint32_t head;
        uint32_t tail;
        uint32_t mask;
        uint32_t entries;
    } sq;

    // Completion queue state
    struct {
        uint32_t head;
        uint32_t tail;
        uint32_t mask;
        uint32_t entries;
    } cq;

    // SQE and CQE arrays (kernel-owned)
    struct io_uring_sqe *sqes;
    struct io_uring_cqe *cqes;

    // Shared memory regions (mapped to userspace)
    void *sq_ring;
    void *cq_ring;

    // State tracking
    uint32_t pending_ops;
    bool shutdown;

    // Wait queues
    waitqueue wait_sq;
    waitqueue wait_cq;

    // Registered buffers for fixed I/O
    void **registered_buffers;
    unsigned nr_registered_buffers;

    // Registered files for fixed I/O
    struct file **registered_files;
    unsigned nr_registered_files;
};

struct io_uring_work {
    struct io_uring_ctx *ctx;
    struct io_uring_sqe sqe;
    sched::thread *thread;
};

// io_uring file class implementing file operations
class io_uring_file final : public file {
public:
    explicit io_uring_file(unsigned flags, struct io_uring_ctx *ctx);
    virtual ~io_uring_file();

    virtual int read(struct uio *uio, int flags) override;
    virtual int write(struct uio *uio, int flags) override;
    virtual int truncate(off_t len) override;
    virtual int ioctl(u_long com, void *data) override;
    virtual int poll(int events) override;
    virtual int stat(struct stat* buf) override;
    virtual int close() override;
    virtual int chmod(mode_t mode) override;
    virtual std::unique_ptr<mmu::file_vma> mmap(addr_range range, unsigned flags, unsigned perm, off_t offset) override;
    virtual bool map_page(uintptr_t offset, mmu::hw_ptep<0> ptep, mmu::pt_element<0> pte, bool write, bool shared) override;
    virtual bool map_page(uintptr_t offset, mmu::hw_ptep<1> ptep, mmu::pt_element<1> pte, bool write, bool shared) override;
    virtual bool put_page(void *addr, uintptr_t offset, mmu::hw_ptep<0> ptep) override;
    virtual bool put_page(void *addr, uintptr_t offset, mmu::hw_ptep<1> ptep) override;

private:
    struct io_uring_ctx *_ctx;
};

static void io_uring_complete_op(struct io_uring_ctx *ctx, uint64_t user_data,
                                  int32_t res, uint32_t flags)
{
    WITH_LOCK(ctx->mtx) {
        unsigned int head, tail;

        // Read head/tail from shared memory if available
        if (ctx->cq_ring) {
            struct io_uring_cq_ring *cq_ring = static_cast<struct io_uring_cq_ring*>(ctx->cq_ring);
            head = __atomic_load_n(&cq_ring->head, __ATOMIC_ACQUIRE);
            tail = __atomic_load_n(&cq_ring->tail, __ATOMIC_ACQUIRE);
        } else {
            head = ctx->cq.head;
            tail = ctx->cq.tail;
        }

        unsigned int next = tail + 1;

        // Check for overflow
        if ((next - head) > ctx->cq.entries) {
            io_uring_debug("io_uring: CQ overflow\n");
            if (ctx->cq_ring) {
                struct io_uring_cq_ring *cq_ring = static_cast<struct io_uring_cq_ring*>(ctx->cq_ring);
                __atomic_fetch_add(&cq_ring->overflow, 1, __ATOMIC_RELAXED);
            }
            return;
        }

        struct io_uring_cqe *cqe = &ctx->cqes[tail & ctx->cq.mask];
        cqe->user_data = user_data;
        cqe->res = res;
        cqe->flags = flags;

        // Memory barrier to ensure CQE is written before tail update
        __atomic_thread_fence(__ATOMIC_RELEASE);

        // Update tail in shared memory and internal state
        if (ctx->cq_ring) {
            struct io_uring_cq_ring *cq_ring = static_cast<struct io_uring_cq_ring*>(ctx->cq_ring);
            __atomic_store_n(&cq_ring->tail, next, __ATOMIC_RELEASE);
        }
        ctx->cq.tail = next;
        ctx->pending_ops--;

        ctx->wait_cq.wake_all(ctx->mtx);
    }
}

static void io_uring_process_sqe_thread(void *arg)
{
    std::unique_ptr<io_uring_work> work(static_cast<io_uring_work*>(arg));
    struct io_uring_ctx *ctx = work->ctx;
    struct io_uring_sqe *sqe = &work->sqe;

    int32_t res = 0;
    struct file *fp = nullptr;

    io_uring_debug("io_uring: processing op=%d fd=%d\n", sqe->opcode, sqe->fd);

    switch (sqe->opcode) {
    case IORING_OP_NOP:
        res = 0;
        break;

    case IORING_OP_READ:
    case IORING_OP_READV: {
        res = fget(sqe->fd, &fp);
        if (res) {
            res = -errno;
            break;
        }

        struct iovec iov;
        struct iovec *iovp;
        size_t iovcnt;

        if (sqe->opcode == IORING_OP_READ) {
            iov.iov_base = reinterpret_cast<void*>(sqe->addr);
            iov.iov_len = sqe->len;
            iovp = &iov;
            iovcnt = 1;
        } else {
            iovp = reinterpret_cast<struct iovec*>(sqe->addr);
            iovcnt = sqe->len;
        }

        size_t bytes_read = 0;
        res = sys_read(fp, iovp, iovcnt, sqe->off, &bytes_read);
        if (res == 0) {
            res = bytes_read;
        } else {
            res = -res;
        }
        fdrop(fp);
        break;
    }

    case IORING_OP_WRITE:
    case IORING_OP_WRITEV: {
        res = fget(sqe->fd, &fp);
        if (res) {
            res = -errno;
            break;
        }

        struct iovec iov;
        struct iovec *iovp;
        size_t iovcnt;

        if (sqe->opcode == IORING_OP_WRITE) {
            iov.iov_base = reinterpret_cast<void*>(sqe->addr);
            iov.iov_len = sqe->len;
            iovp = &iov;
            iovcnt = 1;
        } else {
            iovp = reinterpret_cast<struct iovec*>(sqe->addr);
            iovcnt = sqe->len;
        }

        size_t bytes_written = 0;
        res = sys_write(fp, iovp, iovcnt, sqe->off, &bytes_written);
        if (res == 0) {
            res = bytes_written;
        } else {
            res = -res;
        }
        fdrop(fp);
        break;
    }

    case IORING_OP_FSYNC: {
        res = fget(sqe->fd, &fp);
        if (res) {
            res = -errno;
            break;
        }

        res = sys_fsync(fp);
        res = res ? -res : 0;
        fdrop(fp);
        break;
    }

    default:
        io_uring_debug("io_uring: unsupported op=%d\n", sqe->opcode);
        res = -EINVAL;
        break;
    }

    io_uring_complete_op(ctx, sqe->user_data, res, 0);
}

static int io_uring_submit_sqes(struct io_uring_ctx *ctx, unsigned count)
{
    unsigned int submitted = 0;

    WITH_LOCK(ctx->mtx) {
        if (ctx->shutdown) {
            return -EINVAL;
        }

        // Read head/tail from shared memory if available, otherwise use internal state
        unsigned int head, tail;
        if (ctx->sq_ring) {
            struct io_uring_sq_ring *sq_ring = static_cast<struct io_uring_sq_ring*>(ctx->sq_ring);
            head = __atomic_load_n(&sq_ring->head, __ATOMIC_ACQUIRE);
            tail = __atomic_load_n(&sq_ring->tail, __ATOMIC_ACQUIRE);
        } else {
            head = ctx->sq.head;
            tail = ctx->sq.tail;
        }

        while (submitted < count && head != tail) {
            // Get the index from the ring's index array
            unsigned int array_index = head & ctx->sq.mask;
            unsigned int sqe_index;

            if (ctx->sq_ring) {
                struct io_uring_sq_ring *sq_ring = static_cast<struct io_uring_sq_ring*>(ctx->sq_ring);
                sqe_index = sq_ring->array[array_index];
            } else {
                sqe_index = array_index; // fallback to direct mapping
            }

            if (sqe_index >= ctx->sq.entries) {
                io_uring_debug("io_uring: invalid SQE index %u\n", sqe_index);
                break;
            }

            struct io_uring_sqe *sqe = &ctx->sqes[sqe_index];

            auto work = new io_uring_work;
            work->ctx = ctx;
            work->sqe = *sqe;

            ctx->pending_ops++;
            head++;

            sched::thread *t = sched::thread::make([work] {
                io_uring_process_sqe_thread(work);
            }, sched::thread::attr().detached());
            t->start();

            submitted++;
        }

        // Update head in shared memory and internal state
        if (ctx->sq_ring) {
            struct io_uring_sq_ring *sq_ring = static_cast<struct io_uring_sq_ring*>(ctx->sq_ring);
            __atomic_store_n(&sq_ring->head, head, __ATOMIC_RELEASE);
        }
        ctx->sq.head = head;
    }

    io_uring_debug("io_uring: submitted %u ops\n", submitted);
    return submitted;
}

static int io_uring_wait_cqe(struct io_uring_ctx *ctx, unsigned min_complete)
{
    WITH_LOCK(ctx->mtx) {
        while (true) {
            unsigned int head, tail;

            // Read head/tail from shared memory if available
            if (ctx->cq_ring) {
                struct io_uring_cq_ring *cq_ring = static_cast<struct io_uring_cq_ring*>(ctx->cq_ring);
                head = __atomic_load_n(&cq_ring->head, __ATOMIC_ACQUIRE);
                tail = __atomic_load_n(&cq_ring->tail, __ATOMIC_ACQUIRE);
            } else {
                head = ctx->cq.head;
                tail = ctx->cq.tail;
            }

            unsigned int available = tail - head;
            if (available >= min_complete) {
                return 0;
            }

            if (ctx->shutdown) {
                return -EINVAL;
            }

            if (ctx->pending_ops == 0 && available > 0) {
                return 0;
            }

            ctx->wait_cq.wait(ctx->mtx);
        }
    }
    return 0;
}

// io_uring_file implementation

io_uring_file::io_uring_file(unsigned flags, struct io_uring_ctx *ctx)
    : file(flags, DTYPE_UNSPEC)
    , _ctx(ctx)
{
    f_data = ctx;
}

io_uring_file::~io_uring_file()
{
    // Cleanup handled in close()
}

bool io_uring_file::map_page(uintptr_t offset, mmu::hw_ptep<0> ptep, mmu::pt_element<0> pte, bool write, bool shared)
{
    if (!_ctx) {
        return false;
    }

    // Determine which region this offset belongs to
    constexpr off_t IORING_OFF_SQ_RING = 0ULL;
    constexpr off_t IORING_OFF_CQ_RING = 0x8000000ULL;
    constexpr off_t IORING_OFF_SQES = 0x10000000ULL;

    void *kernel_mem = nullptr;

    if (offset >= IORING_OFF_SQES) {
        // SQE array region
        size_t array_offset = offset - IORING_OFF_SQES;
        kernel_mem = reinterpret_cast<char*>(_ctx->sqes) + array_offset;
    } else if (offset >= IORING_OFF_CQ_RING) {
        // CQ ring region
        size_t ring_offset = offset - IORING_OFF_CQ_RING;
        kernel_mem = reinterpret_cast<char*>(_ctx->cq_ring) + ring_offset;
    } else if (offset >= IORING_OFF_SQ_RING) {
        // SQ ring region
        size_t ring_offset = offset - IORING_OFF_SQ_RING;
        kernel_mem = reinterpret_cast<char*>(_ctx->sq_ring) + ring_offset;
    } else {
        return false;
    }

    if (!kernel_mem) {
        return false;
    }

    // Get the physical address of the kernel memory page
    mmu::phys phys_addr = mmu::virt_to_phys(kernel_mem);
    if (!phys_addr) {
        return false;
    }

    // Determine permissions
    unsigned perm = mmu::perm_read;
    if (write) {
        perm |= mmu::perm_write;
    }

    // Create a leaf PTE mapping the physical address
    pte = mmu::make_leaf_pte(ptep, phys_addr, perm);

    ptep.write(pte);
    return true;
}

bool io_uring_file::map_page(uintptr_t offset, mmu::hw_ptep<1> ptep,
                              mmu::pt_element<1> pte, bool write, bool shared)
{
    if (!_ctx) {
        return false;
    }

    // Determine which region this offset belongs to
    constexpr off_t IORING_OFF_SQ_RING = 0ULL;
    constexpr off_t IORING_OFF_CQ_RING = 0x8000000ULL;
    constexpr off_t IORING_OFF_SQES = 0x10000000ULL;

    void *kernel_mem = nullptr;

    if (offset >= IORING_OFF_SQES) {
        // SQE array region
        size_t array_offset = offset - IORING_OFF_SQES;
        kernel_mem = reinterpret_cast<char*>(_ctx->sqes) + array_offset;
    } else if (offset >= IORING_OFF_CQ_RING) {
        // CQ ring region
        size_t ring_offset = offset - IORING_OFF_CQ_RING;
        kernel_mem = reinterpret_cast<char*>(_ctx->cq_ring) + ring_offset;
    } else if (offset >= IORING_OFF_SQ_RING) {
        // SQ ring region
        size_t ring_offset = offset - IORING_OFF_SQ_RING;
        kernel_mem = reinterpret_cast<char*>(_ctx->sq_ring) + ring_offset;
    } else {
        return false;
    }

    if (!kernel_mem) {
        return false;
    }

    // Get the physical address of the kernel memory page
    mmu::phys phys_addr = mmu::virt_to_phys(kernel_mem);
    if (!phys_addr) {
        return false;
    }

    // Determine permissions
    unsigned perm = mmu::perm_read;
    if (write) {
        perm |= mmu::perm_write;
    }

    // Create a leaf PTE mapping the 2MB physical address
    pte = mmu::make_leaf_pte(ptep, phys_addr, perm);

    ptep.write(pte);
    return true;
}

bool io_uring_file::put_page(void *addr, uintptr_t offset, mmu::hw_ptep<0> ptep)
{
    // io_uring pages are managed by the context, not by individual mappings
    // Don't free the page, just unmap it
    ptep.write(mmu::pt_element<0>());
    return true;
}

bool io_uring_file::put_page(void *addr, uintptr_t offset, mmu::hw_ptep<1> ptep)
{
    // io_uring pages are managed by the context, not by individual mappings
    // Don't free the page, just unmap it
    ptep.write(mmu::pt_element<1>());
    return true;
}

int io_uring_file::read(struct uio *uio, int flags)
{
    return EINVAL;
}

int io_uring_file::write(struct uio *uio, int flags)
{
    return EINVAL;
}

int io_uring_file::truncate(off_t len)
{
    return EINVAL;
}

int io_uring_file::ioctl(u_long com, void *data)
{
    return EINVAL;
}

int io_uring_file::poll(int events)
{
    return 0;
}

int io_uring_file::stat(struct stat* buf)
{
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFREG;
    return 0;
}

int io_uring_file::close()
{
    if (!_ctx) {
        return 0;
    }

    WITH_LOCK(_ctx->mtx) {
        _ctx->shutdown = true;
        _ctx->wait_cq.wake_all(_ctx->mtx);
        _ctx->wait_sq.wake_all(_ctx->mtx);
    }

    while (_ctx->pending_ops > 0) {
        usleep(1000);
    }

    if (_ctx->sq_ring) {
        size_t sq_ring_size = sizeof(struct io_uring_sq_ring) +
                              _ctx->sq.entries * sizeof(uint32_t);
        mmu::munmap(_ctx->sq_ring, sq_ring_size);
    }

    if (_ctx->cq_ring) {
        size_t cq_ring_size = sizeof(struct io_uring_cq_ring) +
                              _ctx->cq.entries * sizeof(struct io_uring_cqe);
        mmu::munmap(_ctx->cq_ring, cq_ring_size);
    }

    // Cleanup registered buffers
    if (_ctx->registered_buffers) {
        delete[] _ctx->registered_buffers;
        _ctx->registered_buffers = nullptr;
    }

    // Cleanup registered files
    if (_ctx->registered_files) {
        for (unsigned i = 0; i < _ctx->nr_registered_files; i++) {
            if (_ctx->registered_files[i]) {
                fdrop(_ctx->registered_files[i]);
            }
        }
        delete[] _ctx->registered_files;
        _ctx->registered_files = nullptr;
    }

    delete[] _ctx->sqes;
    delete[] _ctx->cqes;
    delete _ctx;
    _ctx = nullptr;

    return 0;
}

int io_uring_file::chmod(mode_t mode)
{
    return EINVAL;
}

std::unique_ptr<mmu::file_vma> io_uring_file::mmap(addr_range range, unsigned flags, unsigned perm, off_t offset)
{
    if (!_ctx) {
        throw make_error(EINVAL);
    }

    // Linux io_uring uses three fixed offsets for mmap:
    // 0x0:        SQ ring (metadata + index array)
    // 0x8000000:  CQ ring (metadata + CQE array)
    // 0x10000000: SQE array
    constexpr off_t IORING_OFF_SQ_RING = 0ULL;
    constexpr off_t IORING_OFF_CQ_RING = 0x8000000ULL;
    constexpr off_t IORING_OFF_SQES = 0x10000000ULL;

    size_t size = range.end() - range.start();
    size_t required_size = 0;

    // Validate offset and size
    if (offset == IORING_OFF_SQ_RING) {
        required_size = sizeof(struct io_uring_sq_ring) + _ctx->sq.entries * sizeof(uint32_t);
        if (size < required_size) {
            throw make_error(EINVAL);
        }

        // Allocate and initialize SQ ring if not already done
        if (!_ctx->sq_ring) {
            size_t alloc_size = align_up(required_size, mmu::page_size);
            _ctx->sq_ring = mmu::map_anon(nullptr, alloc_size,
                                          mmu::mmap_populate | mmu::mmap_shared,
                                          mmu::perm_rw);
            if (!_ctx->sq_ring) {
                throw make_error(ENOMEM);
            }

            struct io_uring_sq_ring *sq_ring = static_cast<struct io_uring_sq_ring*>(_ctx->sq_ring);
            sq_ring->head = 0;
            sq_ring->tail = 0;
            sq_ring->ring_mask = _ctx->sq.mask;
            sq_ring->ring_entries = _ctx->sq.entries;
            sq_ring->flags = 0;
            sq_ring->dropped = 0;

            // Initialize index array to identity mapping
            for (unsigned int i = 0; i < _ctx->sq.entries; i++) {
                sq_ring->array[i] = i;
            }
        }

    } else if (offset == IORING_OFF_CQ_RING) {
        required_size = sizeof(struct io_uring_cq_ring) + _ctx->cq.entries * sizeof(struct io_uring_cqe);
        if (size < required_size) {
            throw make_error(EINVAL);
        }

        // Allocate and initialize CQ ring if not already done
        if (!_ctx->cq_ring) {
            size_t alloc_size = align_up(required_size, mmu::page_size);
            _ctx->cq_ring = mmu::map_anon(nullptr, alloc_size,
                                          mmu::mmap_populate | mmu::mmap_shared,
                                          mmu::perm_rw);
            if (!_ctx->cq_ring) {
                throw make_error(ENOMEM);
            }

            struct io_uring_cq_ring *cq_ring = static_cast<struct io_uring_cq_ring*>(_ctx->cq_ring);
            cq_ring->head = 0;
            cq_ring->tail = 0;
            cq_ring->ring_mask = _ctx->cq.mask;
            cq_ring->ring_entries = _ctx->cq.entries;
            cq_ring->overflow = 0;

            // Replace the separate CQE array with the embedded one in the ring
            delete[] _ctx->cqes;
            _ctx->cqes = cq_ring->cqes;
        }

    } else if (offset == IORING_OFF_SQES) {
        required_size = _ctx->sq.entries * sizeof(struct io_uring_sqe);
        if (size < required_size) {
            throw make_error(EINVAL);
        }

        // The SQE array was allocated with new[] in sys_io_uring_setup.
        // Since we can't easily convert new[] memory to a shareable mmap,
        // we need to use map_anon from the start. Check if we need to reallocate.
        // This should only happen on first mmap of the SQE array.
        // Check if sqes pointer is within mapped memory or heap-allocated
        if (!mmu::is_linear_mapped(_ctx->sqes, required_size)) {
            struct io_uring_sqe *old_sqes = _ctx->sqes;
            size_t alloc_size = align_up(required_size, mmu::page_size);

            _ctx->sqes = static_cast<struct io_uring_sqe*>(
                mmu::map_anon(nullptr, alloc_size,
                             mmu::mmap_populate | mmu::mmap_shared,
                             mmu::perm_rw));
            if (!_ctx->sqes) {
                _ctx->sqes = old_sqes; // restore on failure
                throw make_error(ENOMEM);
            }

            // Copy existing data and free old allocation
            memcpy(_ctx->sqes, old_sqes, required_size);
            delete[] old_sqes;
        }

    } else {
        throw make_error(EINVAL);
    }

    // Since OSv doesn't have strict kernel/user separation and we've already
    // allocated the memory with map_anon, we just need to return a file_vma.
    // Use default_file_mmap which will create a VMA and call our map_page
    // to populate it.
    return mmu::default_file_mmap(this, range, flags, perm, offset);
}

extern "C"
OSV_LIBC_API
long sys_io_uring_setup(unsigned entries, struct io_uring_params *params)
{
    if (entries < MIN_ENTRIES || entries > MAX_ENTRIES) {
        return -EINVAL;
    }

    if (!params) {
        return -EFAULT;
    }

    entries = 1U << (32 - __builtin_clz(entries - 1));

    struct io_uring_ctx *ctx = new io_uring_ctx;
    if (!ctx) {
        return -ENOMEM;
    }

    // Initialize submission queue
    ctx->sq.entries = entries;
    ctx->sq.mask = entries - 1;
    ctx->sq.head = 0;
    ctx->sq.tail = 0;
    ctx->sq_ring = nullptr;

    unsigned int cq_entries = entries * 2;
    if (params->flags & IORING_SETUP_CQSIZE) {
        cq_entries = params->cq_entries;
        if (cq_entries < entries || cq_entries > MAX_ENTRIES * 2) {
            delete ctx;
            return -EINVAL;
        }
        cq_entries = 1U << (32 - __builtin_clz(cq_entries - 1));
    }

    // Initialize completion queue
    ctx->cq.entries = cq_entries;
    ctx->cq.mask = cq_entries - 1;
    ctx->cq.head = 0;
    ctx->cq.tail = 0;
    ctx->cq_ring = nullptr;

    ctx->sqes = new io_uring_sqe[entries];
    ctx->cqes = new io_uring_cqe[cq_entries];

    if (!ctx->sqes || !ctx->cqes) {
        delete[] ctx->sqes;
        delete[] ctx->cqes;
        delete ctx;
        return -ENOMEM;
    }

    memset(ctx->sqes, 0, entries * sizeof(struct io_uring_sqe));
    memset(ctx->cqes, 0, cq_entries * sizeof(struct io_uring_cqe));

    // Initialize remaining fields (mutex and condvar are default-constructed)
    ctx->shutdown = false;
    ctx->pending_ops = 0;
    ctx->registered_buffers = nullptr;
    ctx->nr_registered_buffers = 0;
    ctx->registered_files = nullptr;
    ctx->nr_registered_files = 0;

    try {
        fileref f = make_file<io_uring_file>(O_RDWR, ctx);

        int fd;
        int error = fdalloc(f.get(), &fd);
        if (error) {
            delete[] ctx->sqes;
            delete[] ctx->cqes;
            delete ctx;
            return -error;
        }

        params->sq_entries = entries;
        params->cq_entries = cq_entries;
        params->features = 0;

        io_uring_debug("io_uring: setup fd=%d sq=%u cq=%u\n", fd, entries, cq_entries);
        return fd;
    } catch (...) {
        delete[] ctx->sqes;
        delete[] ctx->cqes;
        delete ctx;
        return -ENOMEM;
    }
}

extern "C"
OSV_LIBC_API
int sys_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                       unsigned flags, const void *sig, size_t sigsz)
{
    struct file *fp;
    int error = fget(fd, &fp);
    if (error) {
        return -errno;
    }

    auto* io_uring_fp = dynamic_cast<io_uring_file*>(fp);
    if (!io_uring_fp) {
        fdrop(fp);
        return -EINVAL;
    }

    struct io_uring_ctx *ctx = static_cast<struct io_uring_ctx*>(fp->f_data);

    if (to_submit > 0) {
        int submitted = io_uring_submit_sqes(ctx, to_submit);
        if (submitted < 0) {
            fdrop(fp);
            return submitted;
        }
    }

    if (flags & IORING_ENTER_GETEVENTS) {
        error = io_uring_wait_cqe(ctx, min_complete);
        if (error) {
            fdrop(fp);
            return error;
        }
    }

    fdrop(fp);
    return 0;
}

extern "C"
OSV_LIBC_API
int sys_io_uring_register(int fd, unsigned opcode, void *arg, unsigned nr_args)
{
    struct file *fp;
    int error = fget(fd, &fp);
    if (error) {
        return -errno;
    }

    auto* io_uring_fp = dynamic_cast<io_uring_file*>(fp);
    if (!io_uring_fp) {
        fdrop(fp);
        return -EINVAL;
    }

    struct io_uring_ctx *ctx = static_cast<struct io_uring_ctx*>(fp->f_data);
    int ret = 0;

    WITH_LOCK(ctx->mtx) {
        switch (opcode) {
        case IORING_REGISTER_BUFFERS: {
            if (ctx->registered_buffers != nullptr) {
                ret = -EINVAL;
                break;
            }

            if (nr_args == 0 || nr_args > 1024) {
                ret = -EINVAL;
                break;
            }

            struct iovec *iovecs = static_cast<struct iovec*>(arg);
            ctx->registered_buffers = new void*[nr_args];
            if (!ctx->registered_buffers) {
                ret = -ENOMEM;
                break;
            }

            for (unsigned i = 0; i < nr_args; i++) {
                ctx->registered_buffers[i] = iovecs[i].iov_base;
            }
            ctx->nr_registered_buffers = nr_args;
            io_uring_debug("io_uring: registered %u buffers\n", nr_args);
            break;
        }

        case IORING_UNREGISTER_BUFFERS: {
            if (!ctx->registered_buffers) {
                ret = -EINVAL;
                break;
            }

            delete[] ctx->registered_buffers;
            ctx->registered_buffers = nullptr;
            ctx->nr_registered_buffers = 0;
            io_uring_debug("io_uring: unregistered buffers\n");
            break;
        }

        case IORING_REGISTER_FILES: {
            if (ctx->registered_files != nullptr) {
                ret = -EINVAL;
                break;
            }

            if (nr_args == 0 || nr_args > 1024) {
                ret = -EINVAL;
                break;
            }

            int *fds = static_cast<int*>(arg);
            ctx->registered_files = new file*[nr_args];
            if (!ctx->registered_files) {
                ret = -ENOMEM;
                break;
            }

            for (unsigned i = 0; i < nr_args; i++) {
                struct file *f;
                int err = fget(fds[i], &f);
                if (err) {
                    // Cleanup already registered files
                    for (unsigned j = 0; j < i; j++) {
                        if (ctx->registered_files[j]) {
                            fdrop(ctx->registered_files[j]);
                        }
                    }
                    delete[] ctx->registered_files;
                    ctx->registered_files = nullptr;
                    ret = -errno;
                    goto register_files_done;
                }
                ctx->registered_files[i] = f;
            }
            ctx->nr_registered_files = nr_args;
            io_uring_debug("io_uring: registered %u files\n", nr_args);

register_files_done:
            break;
        }

        case IORING_UNREGISTER_FILES: {
            if (!ctx->registered_files) {
                ret = -EINVAL;
                break;
            }

            for (unsigned i = 0; i < ctx->nr_registered_files; i++) {
                if (ctx->registered_files[i]) {
                    fdrop(ctx->registered_files[i]);
                }
            }
            delete[] ctx->registered_files;
            ctx->registered_files = nullptr;
            ctx->nr_registered_files = 0;
            io_uring_debug("io_uring: unregistered files\n");
            break;
        }

        default:
            ret = -EINVAL;
            break;
        }
    }

    fdrop(fp);
    return ret;
}

extern "C"
long io_uring_setup(unsigned entries, struct io_uring_params *params)
{
    return sys_io_uring_setup(entries, params);
}

extern "C"
int io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                   unsigned flags, const void *sig)
{
    return sys_io_uring_enter(fd, to_submit, min_complete, flags, sig, 0);
}

extern "C"
int io_uring_register(int fd, unsigned opcode, void *arg, unsigned nr_args)
{
    return sys_io_uring_register(fd, opcode, arg, nr_args);
}
