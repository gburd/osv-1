# Crucible Snapshots

## Overview

Crucible supports distributed snapshots across all three downstairs replicas. When a snapshot is created, all three downstairs servers atomically create a point-in-time copy of the region data, ensuring consistency across the distributed system.

## Snapshot Requirements

**Critical:** Snapshots require **3/3 quorum** (all three downstairs servers), unlike normal I/O operations which use 2/3 quorum. This ensures that snapshots are consistent across all replicas.

Requirements for snapshot creation:
- All 3 downstairs servers must be connected and healthy
- The Crucible device must be writable (not read-only mode)
- Each snapshot must have a unique numeric identifier

## Snapshot Operations

### Creating a Snapshot

Use the `crucible-snapshot` tool to create snapshots:

```bash
crucible-snapshot /dev/crucible0 <snapshot_id>
```

Example:
```bash
# Create snapshot with ID 1
crucible-snapshot /dev/crucible0 1

# Create snapshot with timestamp-based ID
crucible-snapshot /dev/crucible0 20240320143000
```

### Snapshot ID Convention

Snapshot IDs are 64-bit unsigned integers (0 to 18,446,744,073,709,551,615). Recommended conventions:

1. **Sequential IDs**: Simple incrementing numbers (1, 2, 3, ...)
   ```bash
   crucible-snapshot /dev/crucible0 1
   crucible-snapshot /dev/crucible0 2
   ```

2. **Timestamp-based IDs**: Use Unix timestamps or formatted timestamps
   ```bash
   # Unix timestamp (seconds since epoch)
   SNAP_ID=$(date +%s)
   crucible-snapshot /dev/crucible0 $SNAP_ID

   # Formatted timestamp: YYYYMMDDHHmmss
   SNAP_ID=$(date +%Y%m%d%H%M%S)
   crucible-snapshot /dev/crucible0 $SNAP_ID
   ```

3. **Semantic versioning**: Encode version numbers
   ```bash
   # Version 2.3.5 -> 2000003000005
   crucible-snapshot /dev/crucible0 2000003000005
   ```

## Integration with ZFS

While Crucible snapshots operate at the block device level, you can combine them with ZFS snapshots for a layered backup strategy:

### Combined Snapshot Strategy

```bash
# 1. Create ZFS snapshot (instant, copy-on-write)
zfs snapshot datapool/app@before-upgrade

# 2. Test changes
echo "new config" > /datapool/app/config.yml

# 3. If satisfied, create Crucible snapshot (distributed, persistent)
SNAP_ID=$(date +%Y%m%d%H%M%S)
crucible-snapshot /dev/crucible0 $SNAP_ID

# 4. ZFS snapshot can now be deleted
zfs destroy datapool/app@before-upgrade
```

### Why Use Both?

**ZFS Snapshots:**
- Instant (copy-on-write)
- No I/O overhead
- Perfect for temporary checkpoints
- Easy rollback
- But: tied to single OSv instance

**Crucible Snapshots:**
- Distributed across 3 servers
- Survive host failures
- Can be restored to different instances
- But: require 3/3 quorum
- But: slower to create

**Best Practice:**
1. Use ZFS snapshots for rapid iteration during development/testing
2. Create Crucible snapshots for important milestones
3. Delete old ZFS snapshots once Crucible snapshot is confirmed

## Programmatic Usage

Applications can create snapshots using the ioctl interface:

```c
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdint.h>

#define CRUCIBLE_IOC_CREATE_SNAPSHOT  _IOW('C', 1, uint64_t)

int create_crucible_snapshot(const char* device, uint64_t snapshot_id)
{
    int fd = open(device, O_RDWR);
    if (fd < 0) {
        return -1;
    }

    int result = ioctl(fd, CRUCIBLE_IOC_CREATE_SNAPSHOT, &snapshot_id);
    close(fd);

    return result;
}

// Usage
int main()
{
    uint64_t snap_id = 20240320;
    if (create_crucible_snapshot("/dev/crucible0", snap_id) == 0) {
        printf("Snapshot created successfully\n");
    } else {
        perror("Snapshot failed");
    }
    return 0;
}
```

## Error Handling

Common errors when creating snapshots:

### EIO (Input/output error)
**Cause:** Not all 3 downstairs servers are available

**Solution:**
- Check connectivity to all 3 downstairs servers
- Ensure all 3 downstairs processes are running
- Verify network connectivity

```bash
# Check which downstairs are connected (from OSv debug output)
# Look for messages like:
#   [Crucible] Connected to downstairs 0: host1:3000
#   [Crucible] Connected to downstairs 1: host2:3000
#   [Crucible] Connected to downstairs 2: host3:3000
```

### EROFS (Read-only file system)
**Cause:** Crucible device mounted in read-only mode

**Solution:**
- Remount in read-write mode (requires OSv restart with different parameters)

```bash
# Boot without --crucible-readonly flag
./scripts/run.py \
  --crucible=host1:3000,host2:3000,host3:3000 \
  --crucible-uuid=my-region-uuid
```

### ENODEV (No such device)
**Cause:** Crucible client not initialized or device not available

**Solution:**
- Verify device exists: `ls -l /dev/crucible0`
- Check Crucible initialization messages in boot log

## Snapshot Lifecycle

### Creation

When you create a snapshot:

1. OSv sends Flush message with `snapshot_details` to all 3 downstairs
2. Each downstairs creates a snapshot atomically
3. All 3 downstairs must acknowledge (3/3 quorum)
4. Snapshot is available for restore operations

### Persistence

Snapshots are stored persistently on the downstairs servers and survive:
- OSv instance restart
- Crucible upstairs client restart
- Network disconnections
- Individual downstairs restarts (as long as data is preserved)

### Deletion

**Note:** The current implementation does not provide a delete interface. Snapshot deletion must be performed directly on the downstairs servers using Crucible administrative tools (outside the scope of OSv integration).

Future work: Add `CRUCIBLE_IOC_DELETE_SNAPSHOT` ioctl.

## Snapshot Restore

**Important:** The current Crucible protocol version (v13) does not expose a snapshot restore operation to the upstairs client. Snapshot restore is performed at the downstairs level before the upstairs connects.

### Restore Workflow

To restore from a snapshot:

1. **Stop the OSv instance**
2. **On each downstairs server**, use Crucible administrative tools to restore:
   ```bash
   # Example (actual command depends on Crucible downstairs implementation)
   crucible-downstairs restore --snapshot <snapshot_id> --region /storage/vol1-replica1
   ```
3. **Restart the OSv instance** with same Crucible parameters
4. **Verify data** after restore

### Alternative: Clone from Snapshot

Instead of restoring in-place, you can create a new region from a snapshot:

1. Create new region from snapshot on downstairs servers
2. Boot new OSv instance pointing to the cloned region
3. Original region remains unchanged

This allows:
- Testing without modifying production data
- Parallel environments (prod + staging from same snapshot)
- Disaster recovery scenarios

## Best Practices

1. **Use timestamps for snapshot IDs**
   - Makes it easy to identify when snapshot was created
   - Example: `YYYYMMDDHHMMSS` format

2. **Create snapshots before risky operations**
   - Software upgrades
   - Schema migrations
   - Configuration changes

3. **Verify 3/3 connectivity before important snapshots**
   - Check OSv boot logs for all 3 downstairs connections
   - Test with a dummy snapshot ID first

4. **Document snapshot IDs**
   - Keep a log mapping snapshot IDs to descriptions
   - Example: `20240320143000 -> Before database schema upgrade v2.5`

5. **Combine with ZFS snapshots**
   - Use ZFS for rapid checkpoints during active work
   - Create Crucible snapshot for milestone backups
   - Delete old ZFS snapshots after Crucible snapshot succeeds

6. **Test restore procedure**
   - Periodically test restoring from snapshots
   - Verify data integrity after restore
   - Document restore time and process

## Performance Considerations

Snapshot creation performance:

- **Latency:** Depends on downstairs implementation and network
- **I/O impact:** Minimal (copy-on-write at downstairs level)
- **Quorum requirement:** 3/3 means any downstairs failure blocks snapshot
- **Network overhead:** Only metadata (no data transfer for snapshot creation)

Tips for optimal performance:

1. Create snapshots during low-traffic periods if possible
2. Ensure reliable network connections to all 3 downstairs
3. Monitor downstairs server health before snapshot operations
4. Use fast storage for downstairs (SSDs recommended)

## Troubleshooting

### Snapshot hangs or times out

**Symptoms:**
- `crucible-snapshot` command doesn't return
- Timeout messages in OSv logs

**Diagnosis:**
1. Check if all 3 downstairs are responding
2. Check network latency/packet loss
3. Check downstairs server logs

**Solution:**
- Restart unresponsive downstairs server
- Fix network issues
- Increase timeout (may require code change)

### Snapshot succeeds but can't be listed

**Issue:** Current implementation doesn't provide snapshot listing from upstairs

**Workaround:**
- Query downstairs servers directly for snapshot list
- Keep external record of snapshot IDs and timestamps

### Inconsistent snapshot across replicas

**This should never happen** - the 3/3 quorum requirement ensures all replicas create snapshots atomically.

**If this occurs:**
- Check downstairs server logs for errors
- Verify all 3 downstairs acknowledged the snapshot
- File a bug report with detailed logs

## Future Enhancements

Planned improvements to snapshot support:

1. **Snapshot listing** - List available snapshots from upstairs
2. **Snapshot deletion** - Delete snapshots via ioctl
3. **Snapshot restore** - Restore from snapshot without downstairs restart
4. **Snapshot metadata** - Store descriptions/tags with snapshots
5. **Incremental snapshots** - Reduce storage overhead
6. **Snapshot verification** - Check snapshot integrity

## See Also

- [ZFS on Crucible Documentation](zfs-crucible-distributed-storage.md)
- [Crucible Driver Testing Guide](../tests/README.md)
- Crucible Protocol Specification (external)
