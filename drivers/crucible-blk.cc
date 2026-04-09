/*
 * Crucible distributed block device driver for OSv
 *
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Implementation: Pure C++ (no Rust dependencies)
 * Protocol: v13 compatible with Oxide Crucible downstairs
 * Features: Triple replication, snapshots, DISCARD, pipelining
 *
 * Note: Includes custom C++ implementation of Rust's bincode serialization.
 */

#include "crucible-blk.hh"
#include "crucible-client.hh"
#include "crucible-types.hh"
#include "blk-common.hh"

#include <osv/device.h>
#include <osv/bio.h>
#include <osv/debug.h>
#include <osv/options.hh>

#include <string>
#include <vector>
#include <memory>
#include <cstring>
#include <cctype>
#include <algorithm>
#include <errno.h>

using namespace crucible;

/**
 * Private data for Crucible block device.
 */
struct crucible_priv {
    std::unique_ptr<UpsairsClient> client;
    uint64_t disk_size;
    uint32_t block_size;
    bool read_only;
};

static int crucible_instance = 0;

// Maximum number of Crucible devices supported
#define MAX_CRUCIBLE_DEVICES 8

/**
 * Parse UUID string in format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
 *
 * @param uuid_str UUID string to parse
 * @param uuid Output UUID structure
 * @return true on success, false on parse error
 */
static bool parse_uuid_string(const std::string& uuid_str, Uuid& uuid)
{
    if (uuid_str.length() != 36) {
        return false;
    }

    // Expected format: 8-4-4-4-12 hex digits with hyphens
    if (uuid_str[8] != '-' || uuid_str[13] != '-' ||
        uuid_str[18] != '-' || uuid_str[23] != '-') {
        return false;
    }

    // Parse hex bytes
    int byte_idx = 0;
    for (size_t i = 0; i < uuid_str.length() && byte_idx < 16; i++) {
        char c = uuid_str[i];
        if (c == '-') {
            continue;
        }
        if (!std::isxdigit(c)) {
            return false;
        }

        // Parse two hex digits into one byte
        if (i + 1 >= uuid_str.length() || uuid_str[i + 1] == '-') {
            return false;
        }

        char hex[3] = {c, uuid_str[i + 1], '\0'};
        uuid.bytes[byte_idx++] = static_cast<uint8_t>(std::strtoul(hex, nullptr, 16));
        i++;
    }

    return byte_idx == 16;
}

/**
 * Parse target list: host1:port1,host2:port2,host3:port3
 *
 * @param targets_str Comma-separated target list
 * @return Vector of target strings
 */
static std::vector<std::string> parse_targets(const std::string& targets_str)
{
    std::vector<std::string> targets;
    size_t start = 0;
    size_t end = 0;

    while ((end = targets_str.find(',', start)) != std::string::npos) {
        if (end > start) {
            targets.push_back(targets_str.substr(start, end - start));
        }
        start = end + 1;
    }

    // Add last target
    if (start < targets_str.length()) {
        targets.push_back(targets_str.substr(start));
    }

    return targets;
}

/**
 * Convert Crucible error to errno value.
 */
__attribute__((unused))
static int crucible_error_to_errno(CrucibleError error)
{
    switch (error) {
        case CrucibleError::IoError:
            return EIO;
        case CrucibleError::GenNumberMismatch:
        case CrucibleError::DecryptionError:
        case CrucibleError::HashMismatch:
            return EIO;
        case CrucibleError::InvalidBlockSize:
        case CrucibleError::InvalidOffset:
            return EINVAL;
        case CrucibleError::ConnectionError:
        case CrucibleError::ProtocolError:
            return ENOTCONN;
        case CrucibleError::QuorumFailed:
            return EIO;
        case CrucibleError::Timeout:
            return ETIMEDOUT;
        default:
            return EIO;
    }
}

/**
 * Read operation.
 */
static int crucible_read(struct device *dev, struct uio *uio, int ioflags)
{
    return bdev_read(dev, uio, ioflags);
}

/**
 * Write operation.
 */
static int crucible_write(struct device *dev, struct uio *uio, int ioflags)
{
    auto* prv = static_cast<struct crucible_priv*>(dev->private_data);

    if (prv->read_only) {
        return EROFS;
    }

    return bdev_write(dev, uio, ioflags);
}

/**
 * Ioctl operation for Crucible-specific commands.
 */
static int crucible_ioctl(struct device *dev, u_long cmd, void *arg)
{
    auto* prv = static_cast<struct crucible_priv*>(dev->private_data);

    if (!prv || !prv->client) {
        return ENODEV;
    }

    switch (cmd) {
        case CRUCIBLE_IOC_CREATE_SNAPSHOT: {
            if (prv->read_only) {
                return EROFS;
            }

            // Snapshot ID is passed as argument
            uint64_t snapshot_id = *static_cast<uint64_t*>(arg);

            kprintf("[Crucible] Creating snapshot with ID %lu\n", snapshot_id);
            int result = prv->client->create_snapshot(snapshot_id);

            if (result == 0) {
                kprintf("[Crucible] Snapshot %lu created successfully\n", snapshot_id);
            } else {
                kprintf("[Crucible] Snapshot %lu creation failed with error %d\n",
                        snapshot_id, result);
            }

            return result;
        }

        default:
            // Fall back to generic block device ioctl
            return blk_ioctl(dev, cmd, arg);
    }
}

/**
 * Block I/O strategy function.
 */
static void crucible_strategy(struct bio *bio)
{
    auto* prv = static_cast<struct crucible_priv*>(bio->bio_dev->private_data);
    int error = 0;

    if (!prv || !prv->client) {
        biodone(bio, false);
        return;
    }

    try {
        switch (bio->bio_cmd) {
            case BIO_READ:
                error = prv->client->read_sync(
                    bio->bio_offset,
                    bio->bio_bcount,
                    bio->bio_data
                );
                break;

            case BIO_WRITE:
                if (prv->read_only) {
                    error = EROFS;
                } else {
                    error = prv->client->write_sync(
                        bio->bio_offset,
                        bio->bio_bcount,
                        bio->bio_data
                    );
                }
                break;

            case BIO_FLUSH:
                error = prv->client->flush_sync();
                break;

            case BIO_DISCARD:
                if (prv->read_only) {
                    error = EROFS;
                } else {
                    error = prv->client->discard_sync(
                        bio->bio_offset,
                        bio->bio_bcount
                    );
                }
                break;

            default:
                error = ENOTBLK;
                break;
        }
    } catch (const std::exception& e) {
        kprintf("crucible_strategy: exception: %s\n", e.what());
        error = EIO;
    } catch (...) {
        kprintf("crucible_strategy: unknown exception\n");
        error = EIO;
    }

    bio->bio_error = error;
    biodone(bio, error == 0);
}

/**
 * Device operations structure.
 */
static struct devops crucible_devops = {
    .open = no_open,
    .close = no_close,
    .read = crucible_read,
    .write = crucible_write,
    .ioctl = crucible_ioctl,
    .devctl = no_devctl,
    .strategy = crucible_strategy,
};

/**
 * Driver structure.
 */
static struct driver crucible_driver = {
    .name = "crucible",
    .devops = &crucible_devops,
    .devsz = sizeof(struct crucible_priv),
};

namespace crucible {

/**
 * Initialize Crucible block device driver.
 */
int crucible_init(const std::string& targets_str, const std::string& uuid_str,
                  uint32_t block_size, bool read_only, int device_index)
{
    if (targets_str.empty() || uuid_str.empty()) {
        kprintf("crucible_init: missing required options (--crucible%d and --crucible%d-uuid)\n",
                device_index, device_index);
        return EINVAL;
    }

    if (device_index < 0 || device_index >= MAX_CRUCIBLE_DEVICES) {
        kprintf("crucible_init: invalid device_index %d (must be 0-%d)\n",
                device_index, MAX_CRUCIBLE_DEVICES - 1);
        return EINVAL;
    }

    kprintf("crucible_init: Initializing Crucible block device %d\n", device_index);
    kprintf("crucible_init: targets=%s, uuid=%s, block_size=%u, read_only=%d\n",
            targets_str.c_str(), uuid_str.c_str(), block_size, read_only);

    // Parse targets
    auto targets = parse_targets(targets_str);
    if (targets.size() != 3) {
        kprintf("crucible_init: expected 3 targets, got %zu\n", targets.size());
        return EINVAL;
    }

    // Parse UUID
    Uuid region_uuid;
    if (!parse_uuid_string(uuid_str, region_uuid)) {
        kprintf("crucible_init: invalid UUID format: %s\n", uuid_str.c_str());
        return EINVAL;
    }

    // Create Crucible client
    try {
        // For now, use a default total_blocks value
        // This should be queried from the downstairs servers in a real implementation
        uint64_t total_blocks = 0;  // 0 means query from server

        std::unique_ptr<UpsairsClient> client;
        client.reset(new UpsairsClient(
            targets,
            region_uuid,
            block_size,
            total_blocks,
            read_only,
            false  // encrypted - not supported yet
        ));

        // Connect to downstairs servers (non-blocking with exception handling)
        kprintf("crucible_init: attempting to connect to downstairs servers...\n");
        try {
            client->connect();
        } catch (const std::exception& e) {
            kprintf("crucible_init: WARNING: connection failed: %s\n", e.what());
            kprintf("crucible_init: boot will continue, but /dev/crucible%d will not be available\n",
                    device_index);
            return ENOTCONN;
        }

        if (!client->is_connected()) {
            kprintf("crucible_init: WARNING: failed to establish quorum with downstairs servers\n");
            kprintf("crucible_init: boot will continue, but /dev/crucible%d will not be available\n",
                    device_index);
            return ENOTCONN;
        }

        // Create device with specified index
        std::string dev_name = "crucible" + std::to_string(device_index);
        struct device* dev = device_create(&crucible_driver, dev_name.c_str(), D_BLK);
        crucible_instance = std::max(crucible_instance, device_index + 1);

        auto* prv = static_cast<struct crucible_priv*>(dev->private_data);
        prv->client = std::move(client);
        prv->block_size = block_size;
        prv->disk_size = prv->client->total_size();
        prv->read_only = read_only;

        dev->size = prv->disk_size;
        dev->max_io_size = 1024 * 1024;  // 1MB max I/O

        // Detect partitions
        read_partition_table(dev);

        kprintf("crucible_init: SUCCESS: created device %s, size=%llu bytes, block_size=%u\n",
                dev_name.c_str(), prv->disk_size, prv->block_size);

    } catch (const std::exception& e) {
        kprintf("crucible_init: WARNING: failed to create client: %s\n", e.what());
        kprintf("crucible_init: boot will continue, but /dev/crucible%d will not be available\n",
                device_index);
        return EIO;
    } catch (...) {
        kprintf("crucible_init: WARNING: unknown exception during initialization\n");
        kprintf("crucible_init: boot will continue, but /dev/crucible%d will not be available\n",
                device_index);
        return EIO;
    }

    return 0;
}

} // namespace crucible
