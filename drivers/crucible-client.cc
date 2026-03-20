/*
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include "crucible-client.hh"
#include "crucible-messages.hh"
#include "crucible-hash.hh"

#include <osv/sched.hh>
#include <osv/debug.h>

#include <random>
#include <sstream>
#include <stdexcept>
#include <cstring>
#include <sys/select.h>
#include <errno.h>

// OSv uses kprintf for debug logging
extern "C" {
    int kprintf(const char* fmt, ...);
}

using namespace crucible;

namespace crucible {

// Helper: Generate random UUID
Uuid generate_uuid()
{
    static std::random_device rd;
    static std::mt19937_64 gen(rd());
    static std::uniform_int_distribution<uint8_t> dis(0, 255);

    Uuid uuid;
    for (int i = 0; i < 16; i++) {
        uuid.bytes[i] = dis(gen);
    }

    // Set version (4) and variant bits
    uuid.bytes[6] = (uuid.bytes[6] & 0x0F) | 0x40;  // Version 4
    uuid.bytes[8] = (uuid.bytes[8] & 0x3F) | 0x80;  // Variant 10

    return uuid;
}

// Helper: Parse "host:port" string
std::pair<std::string, uint16_t> parse_target_string(const std::string& target)
{
    auto colon = target.rfind(':');
    if (colon == std::string::npos) {
        throw std::runtime_error("Invalid target format (expected host:port): " + target);
    }

    std::string host = target.substr(0, colon);
    std::string port_str = target.substr(colon + 1);

    try {
        uint16_t port = static_cast<uint16_t>(std::stoul(port_str));
        return {host, port};
    } catch (...) {
        throw std::runtime_error("Invalid port number: " + port_str);
    }
}

// UpsairsClient implementation

UpsairsClient::UpsairsClient(const std::vector<std::string>& targets,
                             const Uuid& region_uuid,
                             uint32_t block_size,
                             uint64_t total_blocks,
                             bool read_only,
                             bool encrypted)
    : targets_(targets)
    , region_uuid_(region_uuid)
    , upstairs_id_(generate_uuid())
    , session_id_(generate_uuid())
    , block_size_(block_size)
    , total_blocks_(total_blocks)
    , read_only_(read_only)
    , encrypted_(encrypted)
{
    if (targets.size() != 3) {
        throw std::runtime_error("Crucible requires exactly 3 downstairs targets");
    }

    if (block_size == 0 || (block_size & (block_size - 1)) != 0) {
        throw std::runtime_error("Block size must be power of 2");
    }
}

UpsairsClient::~UpsairsClient()
{
    disconnect();
}

void UpsairsClient::connect()
{
    if (running_) {
        return;  // Already connected
    }

    // Parse targets and establish connections
    for (size_t i = 0; i < 3; i++) {
        try {
            auto target_pair = parse_target_string(targets_[i]);
            std::string host = target_pair.first;
            uint16_t port = target_pair.second;
            connections_[i].reset(new Connection(host, port));
            connected_count_++;

            kprintf("[Crucible] Connected to downstairs %zu: %s:%u\n\n", i, host.c_str(), port);

        } catch (const std::exception& e) {
            kprintf("[Crucible] Failed to connect to downstairs %zu (%s): %s\n\n", i, targets_[i].c_str(), e.what());
        }
    }

    if (connected_count_ < 2) {
        disconnect();
        throw std::runtime_error("Failed to connect to at least 2 downstairs servers");
    }

    // Perform handshake with all connected downstairs
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                handshake(i);
                query_region_info(i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Handshake/query failed for downstairs %zu: %s\n", i, e.what());
                connections_[i]->close();
                connections_[i].reset();
                connected_count_--;
            }
        }
    }

    if (connected_count_ < 2) {
        disconnect();
        throw std::runtime_error("Failed to complete handshake with at least 2 downstairs");
    }

    // Start I/O thread
    running_ = true;
    io_thread_ = sched::thread::make([this] { this->io_loop(); });
    io_thread_->start();

    kprintf("[Crucible] Upstairs client connected (%d/3 downstairs)\n", connected_count_.load());
}

void UpsairsClient::disconnect()
{
    if (running_) {
        running_ = false;

        if (io_thread_) {
            io_thread_->join();
            delete io_thread_;
            io_thread_ = nullptr;
        }
    }

    // Close connections
    for (auto& conn : connections_) {
        if (conn) {
            conn->close();
            conn.reset();
        }
    }

    connected_count_ = 0;

    // Cancel pending requests
    request_mgr_.cancel_all();
}

bool UpsairsClient::is_connected() const
{
    return connected_count_ >= 2;
}

int UpsairsClient::read_sync(uint64_t offset, uint32_t length, void* buffer)
{
    if (!is_connected()) {
        return EIO;
    }

    // Validate parameters
    if (offset + length > total_size()) {
        return EINVAL;
    }

    if (length % block_size_ != 0 || offset % block_size_ != 0) {
        return EINVAL;
    }

    // Calculate block range
    uint64_t start_block = offset / block_size_;
    uint64_t block_count = length / block_size_;
    uint8_t* data_ptr = static_cast<uint8_t*>(buffer);

    // Allocate job ID
    uint64_t job_id = job_allocator_.allocate();

    // Create pending request
    auto req = request_mgr_.create_request(job_id);

    // Build ReadRequest message
    ReadRequest read_msg;
    read_msg.upstairs_id = upstairs_id_;
    read_msg.session_id = session_id_;
    read_msg.job_id = job_id;
    read_msg.dependencies = {};  // No dependencies for now
    read_msg.start_block = start_block;
    read_msg.count = block_count;

    // Encode message
    auto frame = encode_message(read_msg);

    // Send to all connected downstairs
    int sent_count = 0;
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                connections_[i]->send(frame.data(), frame.size());
                sent_count++;
                kprintf("[Crucible] Sent read job_id=%lu to downstairs %zu\n", job_id, i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Failed to send read to downstairs %zu: %s\n", i, e.what());
            }
        }
    }

    if (sent_count < 2) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Failed to send read to quorum\n");
        return EIO;
    }

    // Wait for quorum
    if (!req->wait_for_quorum()) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Read job_id=%lu failed to reach quorum\n", job_id);
        return EIO;
    }

    // Find first successful response with data
    int source_idx = -1;
    for (int i = 0; i < 3; i++) {
        if (req->downstairs_responded[i] && !req->read_data[i].empty()) {
            source_idx = i;
            break;
        }
    }

    if (source_idx < 0) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Read job_id=%lu: no valid data received\n", job_id);
        return EIO;
    }

    // Verify hash and copy data
    const auto& data = req->read_data[source_idx];
    const auto& contexts = req->read_contexts[source_idx];

    if (data.size() != length || contexts.size() != block_count) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Read job_id=%lu: data size mismatch\n", job_id);
        return EIO;
    }

    // Verify hashes for each block
    for (uint64_t i = 0; i < block_count; i++) {
        const auto& ctx = contexts[i];

        // For unencrypted blocks, verify hash
        if (ctx.type == ReadBlockType::Unencrypted) {
            uint64_t computed_hash = xxhash64_block(data.data() + i * block_size_, block_size_);
            if (computed_hash != ctx.hash) {
                request_mgr_.remove_request(job_id);
                kprintf("[Crucible] Read job_id=%lu: hash mismatch at block %lu\n", job_id, i);
                return EIO;
            }
        }
    }

    // Copy verified data to buffer
    std::memcpy(data_ptr, data.data(), length);

    // Remove request
    request_mgr_.remove_request(job_id);

    kprintf("[Crucible] Read job_id=%lu completed successfully\n", job_id);
    return 0;
}

int UpsairsClient::write_sync(uint64_t offset, uint32_t length, const void* buffer)
{
    if (!is_connected()) {
        return EIO;
    }

    if (read_only_) {
        return EROFS;
    }

    // Validate parameters
    if (offset + length > total_size()) {
        return EINVAL;
    }

    if (length % block_size_ != 0 || offset % block_size_ != 0) {
        return EINVAL;
    }

    // Calculate block range
    uint64_t start_block = offset / block_size_;
    uint64_t block_count = length / block_size_;
    const uint8_t* data_ptr = static_cast<const uint8_t*>(buffer);

    // Allocate job ID
    uint64_t job_id = job_allocator_.allocate();

    // Create pending request
    auto req = request_mgr_.create_request(job_id);

    // Build block contexts with hashes
    std::vector<BlockContext> contexts;
    contexts.reserve(block_count);

    for (uint64_t i = 0; i < block_count; i++) {
        BlockContext ctx;
        ctx.hash = xxhash64_block(data_ptr + i * block_size_, block_size_);
        ctx.encryption_ctx = nullopt;  // No encryption for now
        contexts.push_back(ctx);
    }

    // Build Write message
    Write write_msg;
    write_msg.upstairs_id = upstairs_id_;
    write_msg.session_id = session_id_;
    write_msg.job_id = job_id;
    write_msg.dependencies = {};  // No dependencies for now
    write_msg.start_block = start_block;
    write_msg.contexts = std::move(contexts);

    // Encode message
    auto frame = encode_message(write_msg);

    // Append data blocks to frame
    frame.insert(frame.end(), data_ptr, data_ptr + length);

    // Send to all connected downstairs
    int sent_count = 0;
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                connections_[i]->send(frame.data(), frame.size());
                sent_count++;
                kprintf("[Crucible] Sent write job_id=%lu to downstairs %zu\n", job_id, i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Failed to send write to downstairs %zu: %s\n", i, e.what());
            }
        }
    }

    if (sent_count < 2) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Failed to send write to quorum\n");
        return EIO;
    }

    // Wait for quorum
    if (!req->wait_for_quorum()) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Write job_id=%lu failed to reach quorum\n", job_id);
        return EIO;
    }

    // Remove request
    request_mgr_.remove_request(job_id);

    kprintf("[Crucible] Write job_id=%lu completed successfully\n", job_id);
    return 0;
}

int UpsairsClient::flush_sync()
{
    if (!is_connected()) {
        return EIO;
    }

    if (read_only_) {
        return 0;  // No-op for read-only
    }

    // Allocate job ID
    uint64_t job_id = job_allocator_.allocate();

    // Increment flush number
    flush_number_++;

    // Create pending request
    auto req = request_mgr_.create_request(job_id);

    // Build Flush message
    Flush flush_msg;
    flush_msg.upstairs_id = upstairs_id_;
    flush_msg.session_id = session_id_;
    flush_msg.job_id = job_id;
    flush_msg.dependencies = {};  // No dependencies for now
    flush_msg.flush_number = flush_number_;
    flush_msg.gen_number = generation_;
    flush_msg.snapshot_details = nullopt;  // No snapshot
    flush_msg.extent_limit = region_def_.extent_count;

    // Encode message
    auto frame = encode_message(flush_msg);

    // Send to all connected downstairs
    int sent_count = 0;
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                connections_[i]->send(frame.data(), frame.size());
                sent_count++;
                kprintf("[Crucible] Sent flush job_id=%lu flush_num=%lu to downstairs %zu",
                      job_id, flush_number_, i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Failed to send flush to downstairs %zu: %s\n", i, e.what());
            }
        }
    }

    if (sent_count < 2) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Failed to send flush to quorum\n");
        return EIO;
    }

    // Wait for quorum
    if (!req->wait_for_quorum()) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Flush job_id=%lu failed to reach quorum\n", job_id);
        return EIO;
    }

    // Remove request
    request_mgr_.remove_request(job_id);

    kprintf("[Crucible] Flush job_id=%lu completed successfully\n", job_id);
    return 0;
}

int UpsairsClient::create_snapshot(uint64_t snapshot_id)
{
    if (!is_connected()) {
        return EIO;
    }

    if (read_only_) {
        return EROFS;  // Cannot create snapshots in read-only mode
    }

    // Snapshots require 3/3 quorum (not 2/3)
    if (connected_count_ < 3) {
        kprintf("[Crucible] Snapshot requires 3/3 downstairs (only %d connected)\n",
                connected_count_.load());
        return EIO;
    }

    // Allocate job ID
    uint64_t job_id = job_allocator_.allocate();

    // Increment flush number
    flush_number_++;

    // Create pending request (requires 3/3 acknowledgments)
    auto req = request_mgr_.create_request(job_id, 3);

    // Build Flush message with snapshot details
    Flush flush_msg;
    flush_msg.upstairs_id = upstairs_id_;
    flush_msg.session_id = session_id_;
    flush_msg.job_id = job_id;
    flush_msg.dependencies = {};
    flush_msg.flush_number = flush_number_;
    flush_msg.gen_number = generation_;
    flush_msg.snapshot_details = snapshot_id;  // Set snapshot ID
    flush_msg.extent_limit = region_def_.extent_count;

    // Encode message
    auto frame = encode_message(flush_msg);

    // Send to ALL downstairs (3/3 required for snapshots)
    int sent_count = 0;
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                connections_[i]->send(frame.data(), frame.size());
                sent_count++;
                kprintf("[Crucible] Sent snapshot flush job_id=%lu snap_id=%lu to downstairs %zu\n",
                      job_id, snapshot_id, i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Failed to send snapshot flush to downstairs %zu: %s\n",
                        i, e.what());
            }
        }
    }

    if (sent_count < 3) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Failed to send snapshot flush to all 3 downstairs (sent to %d)\n",
                sent_count);
        return EIO;
    }

    // Wait for 3/3 quorum
    if (!req->wait_for_quorum()) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Snapshot job_id=%lu snap_id=%lu failed to reach 3/3 quorum\n",
                job_id, snapshot_id);
        return EIO;
    }

    // Remove request
    request_mgr_.remove_request(job_id);

    kprintf("[Crucible] Snapshot job_id=%lu snap_id=%lu completed successfully (3/3)\n",
            job_id, snapshot_id);
    return 0;
}

int UpsairsClient::discard_sync(uint64_t offset, uint64_t length)
{
    if (!is_connected()) {
        return EIO;
    }

    if (read_only_) {
        return EROFS;
    }

    // Validate parameters
    if (offset + length > total_size()) {
        return EINVAL;
    }

    if (length % block_size_ != 0 || offset % block_size_ != 0) {
        return EINVAL;
    }

    // Allocate job ID
    uint64_t job_id = job_allocator_.allocate();

    // Create pending request
    auto req = request_mgr_.create_request(job_id);

    // Build Discard message
    Discard discard_msg;
    discard_msg.upstairs_id = upstairs_id_;
    discard_msg.session_id = session_id_;
    discard_msg.job_id = job_id;
    discard_msg.dependencies = {};
    discard_msg.offset = offset;
    discard_msg.length = length;

    // Encode message
    auto frame = encode_message(discard_msg);

    // Send to all connected downstairs
    int sent_count = 0;
    for (size_t i = 0; i < 3; i++) {
        if (connections_[i] && connections_[i]->is_connected()) {
            try {
                connections_[i]->send(frame.data(), frame.size());
                sent_count++;
                kprintf("[Crucible] Sent discard job_id=%lu offset=%lu length=%lu to downstairs %zu\n",
                      job_id, offset, length, i);
            } catch (const std::exception& e) {
                kprintf("[Crucible] Failed to send discard to downstairs %zu: %s\n", i, e.what());
            }
        }
    }

    if (sent_count < 2) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Failed to send discard to quorum\n");
        return EIO;
    }

    // Wait for quorum
    if (!req->wait_for_quorum()) {
        request_mgr_.remove_request(job_id);
        kprintf("[Crucible] Discard job_id=%lu failed to reach quorum\n", job_id);
        return EIO;
    }

    // Remove request
    request_mgr_.remove_request(job_id);

    kprintf("[Crucible] Discard job_id=%lu completed successfully\n", job_id);
    return 0;
}

std::pair<std::string, uint16_t> UpsairsClient::parse_target(const std::string& target)
{
    return parse_target_string(target);
}

void UpsairsClient::io_loop()
{
    kprintf("[Crucible] I/O thread started\n");

    while (running_) {
        // Use select() to wait for readable connections
        fd_set readfds;
        FD_ZERO(&readfds);
        int max_fd = -1;

        for (size_t i = 0; i < 3; i++) {
            if (connections_[i] && connections_[i]->is_connected()) {
                int fd = connections_[i]->fd();
                FD_SET(fd, &readfds);
                if (fd > max_fd) {
                    max_fd = fd;
                }
            }
        }

        if (max_fd < 0) {
            // No connections, sleep
            sched::thread::sleep(std::chrono::milliseconds(100));
            continue;
        }

        // Wait with timeout
        struct timeval tv = {0, 100000};  // 100ms
        int ret = select(max_fd + 1, &readfds, nullptr, nullptr, &tv);

        if (ret < 0) {
            if (errno == EINTR) {
                // Interrupted, retry
                continue;
            }
            kprintf("[Crucible] select() error: %d\n", errno);
            break;
        }

        if (ret > 0) {
            // Process responses from readable connections
            for (size_t i = 0; i < 3; i++) {
                if (connections_[i] && connections_[i]->is_connected()) {
                    int fd = connections_[i]->fd();
                    if (FD_ISSET(fd, &readfds)) {
                        try {
                            process_responses(i);
                        } catch (const std::exception& e) {
                            kprintf("[Crucible] Response processing error on downstairs %zu: %s",
                                  i, e.what());
                            // Mark connection as failed
                            connections_[i]->close();
                            connected_count_--;
                        }
                    }
                }
            }
        }

        // TODO: Check for timed-out requests periodically
    }

    kprintf("[Crucible] I/O thread stopped\n");
}

void UpsairsClient::process_responses(int downstairs_idx)
{
    // Receive frame
    auto frame = receive_frame(downstairs_idx);

    // Decode message type
    bincode::Decoder dec(frame);
    MessageType type = decode_message_type(dec);

    // Handle different message types
    switch (type) {
        case MessageType::WriteAck: {
            auto ack = WriteAck::decode(dec);
            auto req = request_mgr_.find_request(ack.job_id);
            if (req) {
                req->mark_response(downstairs_idx, ack.result.is_ok,
                                  ack.result.is_ok ? CrucibleError::IoError : ack.result.error);
            } else {
                kprintf("[Crucible] WriteAck for unknown job %lu\n", ack.job_id);
            }
            break;
        }

        case MessageType::ReadResponse: {
            auto resp = ReadResponse::decode(dec);
            auto req = request_mgr_.find_request(resp.job_id);
            if (req) {
                if (resp.blocks.is_ok) {
                    // Receive data following the header
                    size_t block_count = resp.blocks.value.size();
                    size_t data_size = block_count * block_size_;
                    std::vector<uint8_t> data(data_size);
                    connections_[downstairs_idx]->recv_exact(data.data(), data_size);

                    // Store response data and contexts
                    req->read_data[downstairs_idx] = std::move(data);
                    req->read_contexts[downstairs_idx] = std::move(resp.blocks.value);

                    req->mark_response(downstairs_idx, true);
                } else {
                    req->mark_response(downstairs_idx, false, resp.blocks.error);
                }
            } else {
                kprintf("[Crucible] ReadResponse for unknown job %lu\n", resp.job_id);
            }
            break;
        }

        case MessageType::FlushAck: {
            auto ack = FlushAck::decode(dec);
            auto req = request_mgr_.find_request(ack.job_id);
            if (req) {
                req->mark_response(downstairs_idx, ack.result.is_ok,
                                  ack.result.is_ok ? CrucibleError::IoError : ack.result.error);
            } else {
                kprintf("[Crucible] FlushAck for unknown job %lu\n", ack.job_id);
            }
            break;
        }

        case MessageType::DiscardAck: {
            auto ack = DiscardAck::decode(dec);
            auto req = request_mgr_.find_request(ack.job_id);
            if (req) {
                req->mark_response(downstairs_idx, ack.result.is_ok,
                                  ack.result.is_ok ? CrucibleError::IoError : ack.result.error);
            } else {
                kprintf("[Crucible] DiscardAck for unknown job %lu\n", ack.job_id);
            }
            break;
        }

        case MessageType::Imok: {
            // Health check response, ignore for now
            kprintf("[Crucible] Received Imok from downstairs %d\n", downstairs_idx);
            break;
        }

        default:
            kprintf("[Crucible] Unexpected message type from downstairs %d: %u",
                  downstairs_idx, static_cast<uint32_t>(type));
            break;
    }
}

void UpsairsClient::handshake(int downstairs_idx)
{
    auto& conn = connections_[downstairs_idx];
    if (!conn || !conn->is_connected()) {
        throw ConnectionError("Downstairs not connected");
    }

    // Send HereIAm
    HereIAm here_msg;
    here_msg.version = static_cast<uint32_t>(ProtocolVersion::V13);
    here_msg.upstairs_id = upstairs_id_;
    here_msg.session_id = session_id_;
    here_msg.gen = generation_;
    here_msg.read_only = read_only_;
    here_msg.encrypted = encrypted_;
    here_msg.alternate_region = false;

    auto frame = encode_message(here_msg);
    conn->send(frame.data(), frame.size());

    kprintf("[Crucible] Sent HereIAm to downstairs %d\n", downstairs_idx);

    // Receive response
    auto response_frame = receive_frame(downstairs_idx);
    bincode::Decoder dec(response_frame);

    MessageType type = decode_message_type(dec);

    if (type == MessageType::YesItsMe) {
        auto yes_msg = YesItsMe::decode(dec);

        if (yes_msg.upstairs_id != upstairs_id_) {
            throw std::runtime_error("UUID mismatch in YesItsMe");
        }

        kprintf("[Crucible] Handshake successful with downstairs %d\n", downstairs_idx);

    } else if (type == MessageType::VersionMismatch) {
        auto mismatch = VersionMismatch::decode(dec);
        throw std::runtime_error("Version mismatch: offered " +
                                std::to_string(mismatch.offered));

    } else if (type == MessageType::ReadOnlyMismatch) {
        throw std::runtime_error("Read-only mode mismatch");

    } else if (type == MessageType::EncryptedMismatch) {
        throw std::runtime_error("Encryption mode mismatch");

    } else if (type == MessageType::UuidMismatch) {
        throw std::runtime_error("Region UUID mismatch");

    } else {
        throw std::runtime_error("Unexpected handshake response: " +
                                std::to_string(static_cast<uint32_t>(type)));
    }
}

void UpsairsClient::query_region_info(int downstairs_idx)
{
    auto& conn = connections_[downstairs_idx];
    if (!conn || !conn->is_connected()) {
        throw ConnectionError("Downstairs not connected");
    }

    // Send RegionInfoPlease
    RegionInfoPlease req_msg;
    auto frame = encode_message(req_msg);
    conn->send(frame.data(), frame.size());

    kprintf("[Crucible] Sent RegionInfoPlease to downstairs %d\n", downstairs_idx);

    // Receive RegionInfo response
    auto response_frame = receive_frame(downstairs_idx);
    bincode::Decoder dec(response_frame);

    MessageType type = decode_message_type(dec);
    if (type != MessageType::RegionInfo) {
        throw std::runtime_error("Expected RegionInfo, got " +
                                std::to_string(static_cast<uint32_t>(type)));
    }

    auto info_msg = RegionInfo::decode(dec);
    region_def_ = info_msg.region_def;

    // Validate region definition
    if (region_def_.block_size != block_size_) {
        throw std::runtime_error("Block size mismatch: expected " +
                                std::to_string(block_size_) + ", got " +
                                std::to_string(region_def_.block_size));
    }

    kprintf("[Crucible] Region info: block_size=%u, extent_size=%lu, extents=%lu",
          region_def_.block_size, region_def_.extent_size, region_def_.extent_count);
}

void UpsairsClient::send_frame(int downstairs_idx, const std::vector<uint8_t>& data)
{
    auto& conn = connections_[downstairs_idx];
    if (!conn || !conn->is_connected()) {
        throw ConnectionError("Downstairs not connected");
    }

    // Send length prefix (4 bytes, little-endian)
    uint32_t length = data.size();
    conn->send(&length, 4);

    // Send data
    conn->send(data.data(), data.size());
}

std::vector<uint8_t> UpsairsClient::receive_frame(int downstairs_idx)
{
    auto& conn = connections_[downstairs_idx];
    if (!conn || !conn->is_connected()) {
        throw ConnectionError("Downstairs not connected");
    }

    // Receive length prefix
    uint32_t length;
    conn->recv_exact(&length, 4);

    // Validate length
    if (length > 100 * 1024 * 1024) {  // 100 MB max
        throw std::runtime_error("Frame too large");
    }

    // Receive data
    std::vector<uint8_t> data(length);
    conn->recv_exact(data.data(), length);

    return data;
}

} // namespace crucible
