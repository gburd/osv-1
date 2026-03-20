# ZFS RAID-Z on Crucible with Distributed Storage

## Overview

This document describes how to create a ZFS RAID-Z pool across multiple Crucible volumes in OSv, combining ZFS's single-device redundancy with Crucible's distributed replication for enhanced fault tolerance.

## Architecture

### Component Layers

```
┌─────────────────────────────────────────────────────────────┐
│                    OSv Instance                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  ZFS RAID-Z Pool: datapool                             │ │
│  │                                                          │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │ │
│  │  │crucible0 │  │crucible1 │  │crucible2 │  RAID-Z     │ │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘  (parity)   │ │
│  └───────┼─────────────┼─────────────┼────────────────────┘ │
│          │             │             │                       │
│  ┌───────┼─────────────┼─────────────┼────────────────────┐ │
│  │ Crucible Client Layer (UpsairsClient)                  │ │
│  └───────┼─────────────┼─────────────┼────────────────────┘ │
└──────────┼─────────────┼─────────────┼──────────────────────┘
           │             │             │
           │ Network     │ Network     │ Network
           │             │             │
┌──────────▼─────────────▼─────────────▼──────────────────────┐
│           Crucible Downstairs Servers                        │
│                                                               │
│  Volume 0 (3 replicas)  Volume 1 (3 replicas)  Volume 2     │
│  ┌───┐ ┌───┐ ┌───┐    ┌───┐ ┌───┐ ┌───┐    ┌───┐ ┌───┐    │
│  │ D │ │ D │ │ D │    │ D │ │ D │ │ D │    │ D │ │ D │ │D││
│  │ 0 │ │ 1 │ │ 2 │    │ 0 │ │ 1 │ │ 2 │    │ 0 │ │ 1 │ │2││
│  └───┘ └───┘ └───┘    └───┘ └───┘ └───┘    └───┘ └───┘ └─┘│
│  (2/3 quorum)          (2/3 quorum)          (2/3 quorum)   │
└───────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Write Operation**:
   - ZFS receives write request
   - RAID-Z calculates parity and distributes blocks across 3 devices
   - Each Crucible client sends data to 3 downstairs servers
   - 2/3 quorum required for write success
   - RAID-Z write completes when all volumes acknowledge

2. **Read Operation**:
   - ZFS reads from RAID-Z pool
   - Crucible clients retrieve data from available downstairs
   - RAID-Z can reconstruct data if one device fails
   - Crucible can serve from 1 of 3 replicas per volume

## Prerequisites

### Hardware Requirements

- Network connectivity to downstairs servers
- Sufficient memory for ZFS ARC (recommended: 2GB+ for this example)
- CPU with virtualization support (for QEMU/KVM)

### Software Requirements

1. **Crucible Downstairs Servers**: 9 total instances (3 per volume)
2. **OSv Built with Crucible Support**:
   ```bash
   ./scripts/build conf_drivers_profile=crucible image=native-example
   ```

### Downstairs Server Setup

For testing, you can use mock servers or real Crucible downstairs instances:

```bash
# Volume 0 - ports 3000, 3001, 3002
crucible-downstairs --port 3000 --data /data/vol0-replica0 &
crucible-downstairs --port 3001 --data /data/vol0-replica1 &
crucible-downstairs --port 3002 --data /data/vol0-replica2 &

# Volume 1 - ports 3010, 3011, 3012
crucible-downstairs --port 3010 --data /data/vol1-replica0 &
crucible-downstairs --port 3011 --data /data/vol1-replica1 &
crucible-downstairs --port 3012 --data /data/vol1-replica2 &

# Volume 2 - ports 3020, 3021, 3022
crucible-downstairs --port 3020 --data /data/vol2-replica0 &
crucible-downstairs --port 3021 --data /data/vol2-replica1 &
crucible-downstairs --port 3022 --data /data/vol2-replica2 &
```

## Setup

### Automated Setup (Recommended)

Use the provided test script for automated setup and verification:

```bash
cd /path/to/osv
./tests/zfs-crucible-raidz-l2arc.sh
```

The script will:
1. Build OSv with Crucible support
2. Boot with 3 Crucible volumes
3. Create RAID-Z pool across volumes
4. Write and verify test data
5. Create a snapshot
6. Display pool statistics

### Manual Setup

#### Step 1: Boot OSv with Multiple Crucible Volumes

```bash
./scripts/run.py \
    --crucible0=10.0.0.10:3000,10.0.0.10:3001,10.0.0.10:3002 \
    --crucible0-uuid=raidz-test-vol0 \
    --crucible1=10.0.0.10:3010,10.0.0.10:3011,10.0.0.10:3012 \
    --crucible1-uuid=raidz-test-vol1 \
    --crucible2=10.0.0.10:3020,10.0.0.10:3021,10.0.0.10:3022 \
    --crucible2-uuid=raidz-test-vol2 \
    -e /tests/native-example.so
```

#### Step 2: Verify Devices

Inside OSv:
```bash
ls -l /dev/crucible*
# Should show: /dev/crucible0, /dev/crucible1, /dev/crucible2
```

#### Step 3: Create RAID-Z Pool

```bash
# Create pool with optimal settings
zpool create -f \
    -o ashift=12 \
    -O compression=lz4 \
    -O atime=off \
    datapool raidz /dev/crucible0 /dev/crucible1 /dev/crucible2
```

Options explained:
- `-o ashift=12`: Use 4KB block size (2^12 bytes), optimal for SSDs
- `-O compression=lz4`: Enable fast LZ4 compression
- `-O atime=off`: Disable access time updates to reduce writes
- `raidz`: Single-parity RAID (survives 1 device failure)

#### Step 4: Verify Pool Status

```bash
# Check pool health
zpool status datapool

# View pool capacity
zpool list datapool

# Show pool I/O statistics
zpool iostat -v datapool
```

#### Step 5: Create Datasets and Write Data

```bash
# Create dataset
zfs create datapool/testdata

# Write test data
for i in $(seq 1 50); do
    dd if=/dev/urandom of=/datapool/testdata/file${i}.dat bs=1M count=5
done

# Verify
ls -lh /datapool/testdata/
```

#### Step 6: Create Snapshots

```bash
# Create snapshot
zfs snapshot datapool/testdata@baseline

# List snapshots
zfs list -t snapshot

# View snapshot space usage
zfs list -o name,used,refer -t snapshot
```

## Performance Characteristics

### Write Performance

- **RAID-Z Overhead**: Parity calculation adds CPU overhead
- **Crucible Replication**: Each write goes to 3 downstairs servers
- **Network Latency**: Write latency = max(network RTT to any downstairs)
- **Quorum Wait**: Must wait for 2/3 downstairs to acknowledge

Typical write latency: 5-15ms (depends on network and storage)

### Read Performance

- **Parallel Reads**: RAID-Z can read from multiple devices in parallel
- **Crucible Selection**: Reads from fastest available downstairs replica
- **ZFS ARC**: In-memory cache dramatically improves read performance
- **Compression Benefit**: LZ4 decompression is faster than disk I/O

Typical read latency: 1-10ms (cached), 5-20ms (uncached)

### Capacity Efficiency

For RAID-Z with 3 devices:
- **Raw Capacity**: 3 × volume_size
- **Usable Capacity**: ~2 × volume_size (33% overhead for parity)
- **Compression Gain**: 1.5-3× (depends on data, LZ4 compression)
- **Effective Capacity**: ~3-6 × volume_size (with compression)

## Fault Tolerance

### Failure Scenarios

The architecture can survive multiple simultaneous failures:

#### Single Downstairs Failure per Volume
- **Impact**: None (Crucible uses 2/3 quorum)
- **Recovery**: Automatic (reads from remaining replicas)
- **Write Performance**: Normal (2 replicas sufficient)

#### One Entire Crucible Volume Failure
- **Impact**: None (RAID-Z uses parity)
- **Recovery**: Automatic (data reconstructed from other 2 devices)
- **Write Performance**: Degraded (parity calculations for every read)

#### Multiple Downstairs Failures
- **Tolerated**: Up to 1 downstairs per volume + 1 entire volume
- **Example**: Volume 0 has 2 down, volume 1 has 1 down, volume 2 healthy
  - Volume 0: 1/3 operational (fails)
  - System fails if volume quorum lost

#### Network Partition
- **Scenario**: OSv can reach only some downstairs servers
- **Behavior**: Volumes with <2 reachable downstairs become unavailable
- **RAID-Z**: Can reconstruct if ≥2 volumes operational

### Resilience Summary

| Failure Type | Count Tolerated | Impact |
|--------------|----------------|---------|
| Downstairs per volume | 1 | None |
| Entire volumes | 1 | Degraded performance |
| Network partitions | Complex | Depends on quorum |
| Combined failures | 1 volume + 1 downstairs/volume | System continues |

## Troubleshooting

### Issue: Devices Not Appearing

**Symptoms**:
```
ls: /dev/crucible*: No such file or directory
```

**Causes**:
1. Downstairs servers not running
2. Network connectivity issues
3. Incorrect host/port configuration
4. Firewall blocking ports

**Solutions**:
```bash
# Verify downstairs servers are running
netstat -ln | grep -E '3000|3010|3020'

# Test connectivity from host
telnet 10.0.0.10 3000

# Check OSv boot logs for connection errors
# Look for "crucible_init: WARNING: connection failed"
```

### Issue: Pool Creation Fails

**Symptoms**:
```
cannot create 'datapool': one or more devices is currently unavailable
```

**Causes**:
1. Fewer than 3 devices available
2. Devices already in use by another pool
3. Insufficient permissions

**Solutions**:
```bash
# Verify all 3 devices exist
ls -l /dev/crucible[012]

# Check if devices are in use
zpool import

# Force creation (destroys existing data)
zpool create -f datapool raidz /dev/crucible0 /dev/crucible1 /dev/crucible2
```

### Issue: Poor Write Performance

**Symptoms**: Write operations taking >100ms

**Causes**:
1. Network latency to downstairs
2. Downstairs storage slow
3. CPU bottleneck (parity calculation)

**Solutions**:
```bash
# Check pool I/O stats
zpool iostat -v datapool 5

# Monitor network latency
ping -c 10 10.0.0.10

# Check CPU usage in OSv
top

# Disable compression if CPU-bound
zfs set compression=off datapool
```

### Issue: "Cannot Open Device" Errors

**Symptoms**:
```
cannot open '/dev/crucible0': No such device
```

**Causes**:
1. Device created after zpool command ran
2. Device permissions issue
3. Crucible connection dropped after boot

**Solutions**:
```bash
# Wait for devices to appear (up to 30s)
for i in {1..30}; do
    [ -e /dev/crucible0 ] && break
    sleep 1
done

# Verify device readability
dd if=/dev/crucible0 of=/dev/null bs=4k count=1

# Check dmesg for crucible driver errors
dmesg | grep -i crucible
```

## Advanced Configuration

### Adding L2ARC (Cache Device)

If a local NVMe device is available:

```bash
# Add L2ARC cache device
zpool add datapool cache /dev/nvme0n1p1

# Verify
zpool status datapool
```

Benefits:
- Frequently accessed data cached locally
- Reduces network traffic to downstairs
- Improves read latency for hot data

### Tuning ZFS for Distributed Storage

```bash
# Increase ARC size (if memory available)
echo "options zfs zfs_arc_max=2147483648" > /etc/modprobe.d/zfs.conf
# 2GB ARC

# Adjust recordsize for workload
zfs set recordsize=128k datapool  # For large sequential I/O
zfs set recordsize=8k datapool    # For small random I/O

# Enable deduplication (if duplicates expected)
zfs set dedup=on datapool  # WARNING: High memory usage

# Adjust sync behavior
zfs set sync=standard datapool  # Default: fsync waits for disk
zfs set sync=disabled datapool  # Faster but less durable
```

### Monitoring and Metrics

```bash
# Continuous pool I/O monitoring
zpool iostat -v datapool 5  # Update every 5 seconds

# Detailed dataset statistics
zfs get all datapool/testdata

# ARC statistics
cat /proc/spl/kstat/zfs/arcstats

# Compression ratio
zfs get compressratio datapool

# Snapshot differential
zfs diff datapool/testdata@baseline
```

## Limitations and Future Work

### Current Limitations

1. **No Dynamic Resize**: Cannot add/remove devices from RAID-Z vdev
2. **No Scrubbing**: Periodic data integrity checks not yet implemented
3. **No Auto-Rebuild**: Manual intervention required after device replacement
4. **Maximum 8 Devices**: Limited by MAX_CRUCIBLE_DEVICES constant
5. **No RAID-Z2/Z3**: Only single-parity RAID-Z supported

### Planned Enhancements

1. **RAID-Z2 Support**: Dual-parity for 2-device fault tolerance
2. **Hot Spare**: Automatic failover to spare devices
3. **Online Resize**: Add capacity without downtime
4. **Scrub Scheduler**: Automated integrity checking
5. **Trim/Discard**: Space reclamation support
6. **Multi-Pool**: Multiple RAID-Z pools per instance

## References

- [ZFS on Linux Documentation](https://openzfs.github.io/openzfs-docs/)
- [Crucible Storage Documentation](docs/crucible-usage.md)
- [OSv ZFS Integration](docs/zfs-crucible-distributed-storage.md)
- [ZFS RAID-Z Performance](https://www.delphix.com/blog/delphix-engineering/zfs-raidz-stripe-width-or-how-i-learned-stop-worrying-and-love-raidz)

## Appendix: Example Output

### Successful Pool Creation

```
# zpool status datapool
  pool: datapool
 state: ONLINE
  scan: none requested
config:

    NAME           STATE     READ WRITE CKSUM
    datapool       ONLINE       0     0     0
      raidz1-0     ONLINE       0     0     0
        crucible0  ONLINE       0     0     0
        crucible1  ONLINE       0     0     0
        crucible2  ONLINE       0     0     0

errors: No known data errors
```

### Pool Statistics

```
# zpool list datapool
NAME       SIZE  ALLOC   FREE  CKPOINT  EXPANDSZ   FRAG    CAP  DEDUP  HEALTH  ALTROOT
datapool  29.5G   250M  29.3G        -         -     0%    0%  1.00x  ONLINE  -
```

### Dataset with Compression

```
# zfs get used,available,compressratio datapool/testdata
NAME               PROPERTY        VALUE  SOURCE
datapool/testdata  used            167M   -
datapool/testdata  available       19.2G  -
datapool/testdata  compressratio   1.50x  -
```
