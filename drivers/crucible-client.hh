/*
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef CRUCIBLE_CLIENT_HH
#define CRUCIBLE_CLIENT_HH

#include "crucible-connection.hh"
#include "crucible-types.hh"
#include "crucible-request.hh"
#include <osv/sched.hh>
#include <string>
#include <vector>
#include <memory>
#include <atomic>

namespace crucible {

/**
 * Crucible upstairs client.
 *
 * Implements the Crucible upstairs protocol for distributed block storage.
 * Connects to 3 downstairs servers and implements 2/3 quorum logic.
 *
 * Thread-safety: Safe for concurrent operations from multiple threads.
 */
class UpsairsClient {
public:
    /**
     * Create an upstairs client.
     *
     * @param targets Vector of "host:port" strings for downstairs servers
     * @param region_uuid UUID of the region
     * @param block_size Block size in bytes (e.g., 512, 4096)
     * @param total_blocks Total number of blocks in volume
     * @param read_only Open in read-only mode
     * @param encrypted Expect encrypted blocks
     */
    UpsairsClient(const std::vector<std::string>& targets,
                  const Uuid& region_uuid,
                  uint32_t block_size,
                  uint64_t total_blocks,
                  bool read_only = false,
                  bool encrypted = false);

    ~UpsairsClient();

    // Non-copyable, non-movable
    UpsairsClient(const UpsairsClient&) = delete;
    UpsairsClient& operator=(const UpsairsClient&) = delete;
    UpsairsClient(UpsairsClient&&) = delete;
    UpsairsClient& operator=(UpsairsClient&&) = delete;

    /**
     * Connect to downstairs servers and perform handshake.
     *
     * @throws ConnectionError on connection failure
     * @throws std::runtime_error on protocol error
     */
    void connect();

    /**
     * Disconnect from downstairs servers.
     */
    void disconnect();

    /**
     * Check if connected to downstairs servers.
     *
     * @return true if at least 2/3 downstairs connected
     */
    bool is_connected() const;

    /**
     * Synchronous read operation.
     *
     * @param offset Byte offset
     * @param length Byte length
     * @param buffer Buffer to read into
     * @return 0 on success, error code on failure
     */
    int read_sync(uint64_t offset, uint32_t length, void* buffer);

    /**
     * Synchronous write operation.
     *
     * @param offset Byte offset
     * @param length Byte length
     * @param buffer Buffer to write from
     * @return 0 on success, error code on failure
     */
    int write_sync(uint64_t offset, uint32_t length, const void* buffer);

    /**
     * Synchronous flush operation.
     *
     * @return 0 on success, error code on failure
     */
    int flush_sync();

    /**
     * Synchronous flush with snapshot creation.
     *
     * Creates a snapshot as part of the flush operation. Requires 3/3 quorum.
     *
     * @param snapshot_id Snapshot identifier (numeric)
     * @return 0 on success, error code on failure
     */
    int create_snapshot(uint64_t snapshot_id);

    /**
     * Synchronous discard (trim) operation.
     *
     * Discards/deallocates blocks in the given range. Used for TRIM/UNMAP.
     *
     * @param offset Byte offset (must be block-aligned)
     * @param length Length in bytes (must be block-aligned)
     * @return 0 on success, error code on failure
     */
    int discard_sync(uint64_t offset, uint64_t length);

    /**
     * Get block size.
     *
     * @return Block size in bytes
     */
    uint32_t block_size() const { return block_size_; }

    /**
     * Get total size.
     *
     * @return Total size in bytes
     */
    uint64_t total_size() const { return total_blocks_ * block_size_; }

    /**
     * Get region information.
     *
     * @return Region definition
     */
    const RegionDefinition& region_info() const { return region_def_; }

private:
    // Configuration
    std::vector<std::string> targets_;
    Uuid region_uuid_;
    Uuid upstairs_id_;        // Generated on first connection
    Uuid session_id_;         // Generated per session
    uint32_t block_size_;
    uint64_t total_blocks_;
    uint64_t generation_{0};
    uint64_t flush_number_{0};  // Incremented on each flush
    bool read_only_;
    bool encrypted_;

    // Connections (3 downstairs servers)
    std::array<std::unique_ptr<Connection>, 3> connections_;
    std::atomic<int> connected_count_{0};

    // Request tracking
    JobIdAllocator job_allocator_;
    RequestManager request_mgr_;

    // I/O thread
    sched::thread* io_thread_{nullptr};
    std::atomic<bool> running_{false};

    // Region information (from handshake)
    RegionDefinition region_def_;

    // Private methods

    /**
     * Parse "host:port" string.
     *
     * @param target Target string
     * @return Pair of (host, port)
     */
    std::pair<std::string, uint16_t> parse_target(const std::string& target);

    /**
     * I/O thread main loop.
     */
    void io_loop();

    /**
     * Process responses from a downstairs server.
     *
     * @param downstairs_idx Index of downstairs (0-2)
     */
    void process_responses(int downstairs_idx);

    /**
     * Perform handshake with a downstairs server.
     *
     * @param downstairs_idx Index of downstairs (0-2)
     * @throws std::runtime_error on handshake failure
     */
    void handshake(int downstairs_idx);

    /**
     * Query region information from downstairs.
     *
     * @param downstairs_idx Index of downstairs (0-2)
     * @throws std::runtime_error on query failure
     */
    void query_region_info(int downstairs_idx);

    /**
     * Receive a frame (length prefix + data).
     *
     * @param downstairs_idx Index of downstairs (0-2)
     * @return Received data
     */
    std::vector<uint8_t> receive_frame(int downstairs_idx);
};

/**
 * Generate a random UUID.
 *
 * @return Random UUID
 */
Uuid generate_uuid();

/**
 * Parse "host:port" string.
 *
 * @param target Target string
 * @return Pair of (host, port)
 * @throws std::runtime_error on parse error
 */
std::pair<std::string, uint16_t> parse_target_string(const std::string& target);

} // namespace crucible

#endif // CRUCIBLE_CLIENT_HH
