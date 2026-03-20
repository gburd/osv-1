# Crucible Integration with Modern I/O

## Overview

This document describes how the Crucible block device driver integrates with modern I/O subsystems in OSv, including multiqueue block layers and io_uring.

## Architecture

### Current I/O Path

```
Application
    ↓
VFS/File System (ZFS, etc.)
    ↓
Block Layer (bio)
    ↓
Crucible Block Device Driver
    ↓
Crucible Upstairs Client
    ↓
Network (3x connections to downstairs)
```

### Thread Model

The current implementation uses:
- **Single strategy thread** per bio request
- **Single I/O thread** for response processing
- **Multiple connections** (one per downstairs)

## Multiqueue Integration

### Background

The multiqueue block layer (blk-mq) improves performance by:
- Eliminating single-queue lock contention
- Enabling per-CPU queues
- Supporting parallel request submission
- Better NUMA locality

### Integration Design

**From feat/trim-discard-multiq branch:**

The multiqueue support provides:
1. **Per-CPU submission queues**
2. **Hardware queue mapping**
3. **Tag-based request tracking**
4. **Lock-free submission**

### Crucible + Multiqueue

```
Application Threads
    ↓
Per-CPU Software Queues (blk-mq)
    ↓
Hardware Dispatch Queues
    ↓
Crucible Block Device Driver
    ↓
Crucible Client (with per-queue contexts)
```

### Implementation Strategy

**Phase 1: Enable multiqueue support**

```cpp
// In crucible-blk.cc
struct crucible_queue_ctx {
    UpsairsClient* client;
    uint16_t queue_id;
    std::atomic<uint64_t> submitted;
    std::atomic<uint64_t> completed;
};

static int crucible_init_queue(struct request_queue *q, void *data)
{
    auto* prv = static_cast<crucible_priv*>(data);
    auto* qctx = new crucible_queue_ctx();
    qctx->client = prv->client.get();
    qctx->queue_id = q->queue_num;
    q->queuedata = qctx;
    return 0;
}

static void crucible_exit_queue(struct request_queue *q)
{
    auto* qctx = static_cast<crucible_queue_ctx*>(q->queuedata);
    delete qctx;
}

static struct blk_mq_ops crucible_mq_ops = {
    .init_request = crucible_init_request,
    .queue_rq = crucible_queue_rq,
    .complete = crucible_complete_request,
    .init_hctx = crucible_init_queue,
    .exit_hctx = crucible_exit_queue,
};
```

**Phase 2: Per-queue request tracking**

Instead of a global RequestManager, use per-queue tracking:

```cpp
class QueuedRequestManager {
    uint16_t queue_id_;
    RequestManager request_mgr_;  // Per-queue manager

public:
    QueuedRequestManager(uint16_t qid) : queue_id_(qid) {}

    std::shared_ptr<PendingRequest> submit_read(uint64_t offset, size_t length);
    std::shared_ptr<PendingRequest> submit_write(uint64_t offset, size_t length);
    // ...
};
```

**Phase 3: Lock-free fast path**

For maximum performance, avoid locks in the common case:

```cpp
// Use atomic operations for request tracking
std::atomic<uint64_t> next_job_id_;
std::atomic<uint32_t> in_flight_reads_;
std::atomic<uint32_t> in_flight_writes_;

// Lock-free request submission
uint64_t submit_request_lockfree() {
    uint64_t job_id = next_job_id_.fetch_add(1, std::memory_order_relaxed);
    // ...
    return job_id;
}
```

### Benefits of Multiqueue + Crucible

1. **Parallel submission** - Multiple CPUs submit I/O concurrently
2. **No lock contention** - Each queue operates independently
3. **Better cache locality** - Per-CPU data structures
4. **Higher throughput** - Saturate network and downstairs IOPS
5. **Lower latency** - Reduced queuing delays

### Expected Performance Improvement

| Metric | Single Queue | Multiqueue | Improvement |
|--------|--------------|------------|-------------|
| 4KB random read IOPS | 50K | 150K+ | 3x |
| 4KB random write IOPS | 30K | 100K+ | 3x |
| CPU efficiency | 60% | 90%+ | 1.5x |
| Tail latency (P99) | 10ms | 5ms | 2x |

## io_uring Integration

### Background

io_uring is a modern Linux I/O interface providing:
- **Zero-copy I/O** - Direct kernel memory access
- **Batch submission** - Submit multiple requests at once
- **Batch completion** - Harvest multiple completions efficiently
- **Reduced syscalls** - Shared ring buffers
- **Lower latency** - Kernel bypass for fast path

### Integration Design

**From feat/io-uring branch:**

```
Application
    ↓
io_uring submission queue (ring buffer)
    ↓
OSv kernel io_uring handler
    ↓
Block layer
    ↓
Crucible device driver
    ↓
io_uring completion queue (ring buffer)
    ↓
Application
```

### Crucible + io_uring

The integration can happen at multiple levels:

#### Level 1: Application → io_uring → Crucible

Application uses io_uring for I/O, which goes through the standard block layer to Crucible:

```c
// Application code
struct io_uring ring;
io_uring_queue_init(256, &ring, 0);

// Submit read
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_read(sqe, fd, buffer, size, offset);
io_uring_submit(&ring);

// Poll for completion
struct io_uring_cqe *cqe;
io_uring_wait_cqe(&ring, &cqe);
```

Benefits:
- Reduced syscall overhead
- Batching multiple Crucible operations
- Async I/O completion

#### Level 2: Crucible → io_uring → Network

Crucible client uses io_uring for network I/O to downstairs:

```cpp
class UpsairsClient {
    struct io_uring network_ring_;

    void send_async(const std::vector<uint8_t>& data) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&network_ring_);
        io_uring_prep_send(sqe, socket_fd, data.data(), data.size(), 0);
        io_uring_submit(&network_ring_);
    }

    void recv_async(uint8_t* buffer, size_t size) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&network_ring_);
        io_uring_prep_recv(sqe, socket_fd, buffer, size, 0);
        io_uring_submit(&network_ring_);
    }
};
```

Benefits:
- Zero-copy network I/O
- Batch send/recv for multiple downstairs
- Lower CPU overhead
- Better latency (no syscalls in fast path)

### Implementation Strategy

**Phase 1: io_uring for application I/O**

Enable applications to use io_uring with Crucible devices. This requires OSv to support io_uring operations on block devices.

```cpp
// OSv io_uring handler for block devices
int osv_io_uring_prep_read_block(struct io_uring_sqe *sqe,
                                   struct device *dev,
                                   void *buf, size_t len, off_t offset)
{
    // Translate to bio request
    struct bio *bio = alloc_bio();
    bio->bio_dev = dev;
    bio->bio_cmd = BIO_READ;
    bio->bio_data = buf;
    bio->bio_offset = offset;
    bio->bio_bcount = len;

    // Submit and link to io_uring completion
    dev->driver->devops->strategy(bio);

    return 0;
}
```

**Phase 2: io_uring for Crucible network I/O**

Replace synchronous socket operations with io_uring:

```cpp
class IoUringConnection {
    struct io_uring ring_;
    int fd_;

    int send(const void* data, size_t length) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring_);
        io_uring_prep_send(sqe, fd_, data, length, 0);
        io_uring_submit(&ring_);

        struct io_uring_cqe *cqe;
        io_uring_wait_cqe(&ring_, &cqe);

        int result = cqe->res;
        io_uring_cqe_seen(&ring_, cqe);

        return result;
    }

    int recv(void* buffer, size_t length) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring_);
        io_uring_prep_recv(sqe, fd_, buffer, length, 0);
        io_uring_submit(&ring_);

        struct io_uring_cqe *cqe;
        io_uring_wait_cqe(&ring_, &cqe);

        int result = cqe->res;
        io_uring_cqe_seen(&ring_, cqe);

        return result;
    }
};
```

**Phase 3: Full async with batching**

Batch multiple operations for efficiency:

```cpp
class BatchedUpsairsClient {
    struct io_uring ring_;

    void submit_batch(const std::vector<Request>& requests) {
        for (const auto& req : requests) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring_);

            switch (req.type) {
            case RequestType::Write:
                io_uring_prep_send(sqe, connections_[0].fd(),
                                 req.data.data(), req.data.size(), 0);
                break;
            // ... other request types
            }
        }

        // Submit entire batch at once
        io_uring_submit(&ring_);
    }

    void complete_batch() {
        unsigned completed = 0;
        struct io_uring_cqe *cqe;

        while (io_uring_peek_cqe(&ring_, &cqe) == 0) {
            // Process completion
            handle_completion(cqe);
            io_uring_cqe_seen(&ring_, cqe);
            completed++;
        }
    }
};
```

### Expected Performance Improvement

| Metric | Standard I/O | io_uring | Improvement |
|--------|--------------|----------|-------------|
| Syscall overhead | 5-10% | < 1% | 5-10x |
| Small I/O latency | 10μs | 2-5μs | 2-5x |
| Batch throughput | 100K IOPS | 500K+ IOPS | 5x |
| CPU usage | 60% | 30% | 2x |

## Combined: Multiqueue + io_uring + Crucible

The ultimate performance configuration combines both:

```
Application (io_uring)
    ↓
Per-CPU io_uring submission queues
    ↓
Per-CPU blk-mq queues
    ↓
Crucible device driver (multiqueue-aware)
    ↓
Per-queue io_uring network submission
    ↓
3x downstairs (parallel, batched)
```

### Benefits of Combined Approach

1. **Maximum parallelism** - Per-CPU queues at every level
2. **Minimum overhead** - Zero-copy, no syscalls, lock-free
3. **Optimal batching** - Batch at application, block, and network layers
4. **Best latency** - Shortest possible code path
5. **Highest throughput** - Saturate all resources (CPU, network, disk)

### Expected Performance

With multiqueue + io_uring + NVMe downstairs + 25GbE network:

| Metric | Target Performance |
|--------|-------------------|
| 4KB random read IOPS | 500K-1M |
| 4KB random write IOPS | 300K-500K |
| Sequential read throughput | 2-3 GB/s |
| Sequential write throughput | 1-2 GB/s |
| Latency P50 | 200-500μs |
| Latency P99 | 1-2ms |
| CPU efficiency | < 30% for 1M IOPS |

## Implementation Roadmap

### Phase 1: Foundational Support (Current)
- ✅ Basic Crucible driver with 2/3 quorum
- ✅ Snapshot support (3/3 quorum)
- ✅ DISCARD/TRIM support
- ✅ Request pipelining foundation

### Phase 2: Multiqueue Integration (Next)
- Implement blk-mq support in Crucible driver
- Per-queue request tracking
- Lock-free submission paths
- Test and benchmark

### Phase 3: io_uring Integration (Future)
- OSv io_uring support for block devices
- Crucible network I/O via io_uring
- Batched operations
- Test and benchmark

### Phase 4: Optimization (Future)
- Zero-copy I/O paths
- NUMA awareness
- Adaptive pipelining
- Advanced batching strategies

## Testing and Validation

### Multiqueue Testing

```bash
# Test with multiple queues
fio --name=multiq --rw=randread --bs=4k --numjobs=16 --iodepth=32 \
    --filename=/dev/crucible0 --direct=1 --group_reporting

# Verify per-queue stats
cat /sys/block/crucible0/mq/*/stats
```

### io_uring Testing

```bash
# Test with io_uring engine
fio --name=iouring --rw=randread --bs=4k --numjobs=4 --iodepth=32 \
    --filename=/dev/crucible0 --ioengine=io_uring --direct=1

# Compare to sync I/O
fio --name=sync --rw=randread --bs=4k --numjobs=4 \
    --filename=/dev/crucible0 --ioengine=sync --direct=1
```

### Combined Testing

```bash
# Maximum performance test
fio --name=maxperf --rw=randread --bs=4k --numjobs=32 --iodepth=128 \
    --filename=/dev/crucible0 --ioengine=io_uring --direct=1 \
    --group_reporting --runtime=60
```

## See Also

- [Crucible Performance Guide](crucible-performance.md)
- [Crucible Snapshots](crucible-snapshots.md)
- [ZFS on Crucible](zfs-crucible-distributed-storage.md)
