# Crucible Performance Guide

## Overview

This document describes performance characteristics, optimization techniques, and pipelining strategies for the Crucible block device driver in OSv.

## Architecture and Performance Characteristics

### Request Processing Pipeline

```
Application I/O
    ↓
OSv Bio Layer
    ↓
Crucible Block Driver (crucible-blk.cc)
    ↓
UpsairsClient (crucible-client.cc)
    ↓
3x Network Connections
    ↓
3x Downstairs Servers
```

### Latency Components

Total I/O latency = Encoding + Network + Downstairs + Quorum Wait

1. **Encoding** (< 1μs): Bincode serialization of messages
2. **Network** (0.1-10ms): Round-trip time to downstairs servers
3. **Downstairs** (1-10ms): Disk I/O at downstairs (SSD or HDD)
4. **Quorum Wait** (variable): Waiting for 2/3 or 3/3 responses

### Quorum Models

| Operation | Quorum | Latency |
|-----------|--------|---------|
| Read      | 2/3    | ~P50 of fastest 2 downstairs |
| Write     | 2/3    | ~P50 of fastest 2 downstairs |
| Flush     | 2/3    | ~P50 of fastest 2 downstairs |
| Discard   | 2/3    | ~P50 of fastest 2 downstairs |
| Snapshot  | 3/3    | ~P100 of slowest downstairs |

**Key Insight:** 2/3 quorum provides excellent tail latency characteristics because operations complete as soon as the fastest 2 downstairs respond.

## Request Pipelining

### Current Implementation

The current implementation supports basic pipelining:

```cpp
// Multiple requests can be in-flight simultaneously
class RequestManager {
    std::map<uint64_t, std::shared_ptr<PendingRequest>> requests_;
    // Multiple job IDs can be tracked concurrently
};
```

### Pipelining Benefits

**Without pipelining** (sequential):
- Latency = N × (encode + network + downstairs + quorum)
- Throughput = 1 / latency

**With pipelining** (parallel):
- Latency = encode + network + downstairs + quorum  (for each request)
- Throughput = min(network_bandwidth, downstairs_IOPS)

### Effective Pipeline Depth

OSv's bio layer naturally provides pipelining through:
1. Multiple threads issuing I/O
2. Asynchronous bio requests
3. I/O scheduler queuing

The Crucible driver processes bios asynchronously, allowing multiple requests to be in-flight:

```cpp
static void crucible_strategy(struct bio *bio)
{
    // Non-blocking: spawns async operation
    error = prv->client->write_sync(bio->bio_offset, bio->bio_bcount, bio->bio_data);
    biodone(bio, error == 0);
}
```

### Optimal Pipeline Depth

Recommended in-flight request limits:

| Workload | Optimal Depth | Rationale |
|----------|---------------|-----------|
| Random read | 32-128 | High latency, benefits from deep queue |
| Sequential read | 8-32 | Prefetching reduces depth needs |
| Random write | 16-64 | Balance latency and downstairs load |
| Sequential write | 4-16 | Large requests reduce overhead |
| Mixed | 32-64 | General-purpose compromise |

**Implementation Note:** The current driver does not enforce a maximum in-flight limit. For production use, consider adding throttling to prevent memory exhaustion:

```cpp
class RequestPipeline {
    static constexpr size_t MAX_IN_FLIGHT = 128;
    std::atomic<size_t> in_flight_count_{0};

    bool can_submit() const {
        return in_flight_count_ < MAX_IN_FLIGHT;
    }

    void submit_request(JobId job_id) {
        in_flight_count_.fetch_add(1);
    }

    void complete_request(JobId job_id) {
        in_flight_count_.fetch_sub(1);
    }
};
```

## Performance Optimization

### Network Optimization

1. **Use low-latency networking**
   - 10GbE or faster
   - Low-latency switches (< 1μs)
   - Jumbo frames (MTU 9000) for large transfers

2. **Tune TCP parameters** (on OSv host)
   ```bash
   # Example sysctl settings (not all may apply to OSv)
   net.ipv4.tcp_low_latency=1
   net.ipv4.tcp_window_scaling=1
   net.core.rmem_max=134217728
   net.core.wmem_max=134217728
   ```

3. **Colocate downstairs servers** in same datacenter/rack
   - Minimize network hops
   - Reduce latency variance

### Downstairs Optimization

1. **Use SSDs** for Crucible downstairs storage
   - NVMe > SATA SSD > HDD
   - Target < 1ms P99 latency

2. **Separate downstairs on different failure domains**
   - Different physical hosts
   - Different power/network paths
   - Ideally different racks

3. **Tune downstairs I/O**
   - Use io_uring on Linux downstairs
   - Enable direct I/O (O_DIRECT)
   - Disable host page cache for Crucible files

### Block Size Tuning

Larger block sizes reduce overhead:

| Block Size | IOPS Overhead | Large Transfer Efficiency |
|------------|---------------|---------------------------|
| 512 bytes  | High (2000 ops for 1MB) | Low |
| 4 KiB      | Medium (256 ops for 1MB) | Medium |
| 64 KiB     | Low (16 ops for 1MB) | High |

**Recommendation:**
- For general-purpose workloads: 4 KiB
- For large sequential I/O: 64 KiB or higher
- For small random I/O: 4 KiB

**Configure at region creation time:**
```bash
# Example downstairs creation with 4KB blocks
crucible-downstairs create -d /storage/region -b 4096 -s $SIZE
```

### Read Performance

Optimize read path:
1. **ZFS ARC caching** - Keep hot data in memory
2. **Crucible quorum** - 2/3 means faster downstairs wins
3. **Prefetching** - Sequential reads benefit from readahead

### Write Performance

Optimize write path:
1. **Batching** - Combine small writes into larger requests
2. **Write-back caching** - ZFS write combining
3. **Async writes** - Don't wait for fsync unless necessary

### Flush/Fsync Performance

Flushes are expensive:
- Requires 2/3 downstairs to persist to storage
- Blocks until acknowledgment
- Can stall pipeline

**Minimize flush frequency:**
```bash
# ZFS: Increase transaction group timeout (default: 5 seconds)
zfs set sync=disabled mypool/dataset  # For non-critical data only
```

**Or batch operations:**
```bash
# Many writes followed by single fsync
echo data1 > file1
echo data2 > file2
sync  # Single flush for both writes
```

## Benchmarking

### Measuring Crucible Performance

1. **Raw device performance**
   ```bash
   # Random read IOPS
   fio --name=randread --rw=randread --bs=4k --size=1G \
       --filename=/dev/crucible0 --direct=1 --numjobs=4 --iodepth=32

   # Sequential write throughput
   fio --name=seqwrite --rw=write --bs=1M --size=1G \
       --filename=/dev/crucible0 --direct=1
   ```

2. **ZFS on Crucible**
   ```bash
   # Create pool on Crucible
   zpool create testpool /dev/crucible0

   # Random read test
   fio --name=zfsrand --rw=randread --bs=4k --size=1G \
       --directory=/testpool --numjobs=4 --iodepth=32

   # Sequential write test
   fio --name=zfsseq --rw=write --bs=1M --size=1G \
       --directory=/testpool
   ```

3. **Monitor downstairs metrics**
   - Check downstairs logs for IOPS and latency
   - Verify balanced load across all 3 downstairs
   - Look for stragglers (slow downstairs)

### Expected Performance

Approximate performance targets (with 3x NVMe SSD downstairs, 10GbE network):

| Workload | IOPS | Throughput | Latency P99 |
|----------|------|------------|-------------|
| 4KB random read | 50,000-100,000 | 200-400 MB/s | 5-10ms |
| 4KB random write | 30,000-60,000 | 120-240 MB/s | 10-20ms |
| 1MB sequential read | 1,000-2,000 | 1-2 GB/s | 5-10ms |
| 1MB sequential write | 500-1,000 | 500-1000 MB/s | 10-20ms |

**Factors affecting performance:**
- Network latency (each 1ms adds ~1ms to operations)
- Downstairs disk performance
- CPU overhead (encoding/decoding)
- Memory bandwidth (large transfers)

## Monitoring and Debugging

### Key Metrics to Track

1. **IOPS** - Operations per second
2. **Latency** - P50, P99, P99.9 latency
3. **Throughput** - MB/s read and write
4. **Queue depth** - In-flight requests
5. **Error rate** - Failed operations
6. **Downstairs health** - Connected count (should be 3)

### OSv Debug Output

Enable Crucible debug logging:
```cpp
// In crucible-client.cc, kprintf statements show:
// - Connection status
// - Job IDs and operations
// - Quorum results
// - Errors
```

### Downstairs Monitoring

Check downstairs logs for:
- High latency warnings
- I/O errors
- Network disconnections
- Resource exhaustion (disk space, memory)

## Troubleshooting Performance Issues

### Symptom: Low IOPS

**Possible causes:**
1. Insufficient pipeline depth
2. Slow downstairs (check individual downstairs latency)
3. Network bottleneck (check bandwidth utilization)
4. CPU bottleneck (check encoding overhead)

**Solutions:**
- Increase concurrent I/O (more threads, higher queue depth)
- Replace slow downstairs or improve downstairs performance
- Upgrade network
- Profile and optimize hot paths

### Symptom: High Latency

**Possible causes:**
1. Slow downstairs
2. Network latency
3. Quorum delays (waiting for slowest downstairs)
4. Resource contention

**Solutions:**
- Identify slow downstairs (check P99 latency per downstairs)
- Reduce network latency (better switches, shorter paths)
- Consider replacing slow downstairs
- Check for resource contention (disk, CPU, memory)

### Symptom: Variable Performance

**Possible causes:**
1. One downstairs intermittently slow
2. Network congestion
3. Resource competition on downstairs host
4. Garbage collection or compaction on downstairs

**Solutions:**
- Monitor per-downstairs latency over time
- Identify and isolate slow downstairs
- Reduce network congestion (QoS, traffic shaping)
- Tune downstairs resource allocation

## Future Optimizations

Potential improvements to Crucible driver performance:

1. **Zero-copy I/O** - Eliminate memory copies in hot path
2. **Batched sends** - Combine multiple small operations into single network packet
3. **Adaptive pipelining** - Automatically tune queue depth based on latency
4. **NUMA awareness** - Pin threads and allocations to local NUMA node
5. **Connection pooling** - Reuse TCP connections for better cache locality
6. **Compression** - Compress data in-flight (CPU vs network tradeoff)

## See Also

- [Crucible Snapshots](crucible-snapshots.md)
- [ZFS on Crucible](zfs-crucible-distributed-storage.md)
- [Crucible Driver Testing Guide](../tests/README.md)
