/*
 * Copyright (C) 2024 Waldemar Kozaczuk
 * Copyright (C) 2024 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef CRUCIBLE_MESSAGES_HH
#define CRUCIBLE_MESSAGES_HH

#include "crucible-types.hh"
#include "crucible-bincode.hh"
#include <vector>
#include <optional>

namespace crucible {

/**
 * Message type discriminants (must match Rust enum).
 */
enum class MessageType : uint32_t {
    HereIAm = 0,
    YesItsMe = 1,
    VersionMismatch = 2,
    ReadOnlyMismatch = 3,
    EncryptedMismatch = 4,
    UuidMismatch = 5,
    RegionInfoPlease = 6,
    RegionInfo = 7,
    ExtentVersionsPlease = 8,
    ExtentVersions = 9,
    LastFlush = 10,
    Write = 11,
    WriteAck = 12,
    WriteUnwritten = 13,
    WriteUnwrittenAck = 14,
    ReadRequest = 15,
    ReadResponse = 16,
    Flush = 17,
    FlushAck = 18,
    Barrier = 19,
    BarrierAck = 20,
    WriteUnwrittenAckId = 21,
    ReplaceDownstairs = 22,
    ExtentLiveRepair = 23,
    ExtentLiveRepairAckId = 24,
    ExtentLiveReopen = 25,
    ExtentLiveReopenAck = 26,
    ExtentLiveClose = 27,
    ExtentLiveCloseAck = 28,
    ExtentFlushClose = 29,
    ExtentFlushCloseAck = 30,
    ExtentLiveNoOp = 31,
    ExtentLiveNoOpAck = 32,
    Discard = 33,
    DiscardAck = 34,
    Ruok = 35,
    Imok = 36,
    PromoteToActive = 37,
    YouAreNowActive = 38,
    YouAreNoLongerActive = 39,
    ErrorReport = 40,
};

/**
 * Socket address (simplified - IPv4 only for now).
 */
struct SocketAddr {
    uint32_t ip;     // IPv4 address (network byte order)
    uint16_t port;   // Port number

    SocketAddr() : ip(0), port(0) {}
    SocketAddr(uint32_t ip, uint16_t port) : ip(ip), port(port) {}
};

// ============================================================================
// Negotiation Messages
// ============================================================================

/**
 * HereIAm - Initial handshake from upstairs to downstairs.
 */
struct HereIAm {
    static constexpr MessageType TYPE = MessageType::HereIAm;

    uint32_t version;              // Protocol version (13)
    Uuid upstairs_id;              // Persistent upstairs UUID
    Uuid session_id;               // Session UUID
    uint64_t gen;                  // Generation number
    bool read_only;                // Read-only mode
    bool encrypted;                // Encryption expected
    bool alternate_region;         // Alternate region support

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
        enc.encode_u32(version);
        enc.encode_uuid(upstairs_id);
        enc.encode_uuid(session_id);
        enc.encode_u64(gen);
        enc.encode_bool(read_only);
        enc.encode_bool(encrypted);
        enc.encode_bool(alternate_region);
    }
};

/**
 * YesItsMe - Response from downstairs accepting connection.
 */
struct YesItsMe {
    static constexpr MessageType TYPE = MessageType::YesItsMe;

    uint32_t version;
    Uuid upstairs_id;
    Uuid session_id;
    uint64_t gen;
    bool repair_addr_set;
    optional<SocketAddr> repair_addr;

    static YesItsMe decode(bincode::Decoder& dec) {
        YesItsMe msg;
        // Discriminant already consumed
        msg.version = dec.decode_u32();
        msg.upstairs_id = dec.decode_uuid();
        msg.session_id = dec.decode_uuid();
        msg.gen = dec.decode_u64();
        msg.repair_addr_set = dec.decode_bool();

        if (msg.repair_addr_set) {
            // Decode SocketAddr (simplified - IPv4 only)
            uint8_t tag = dec.decode_u8();  // 0=IPv4, 1=IPv6
            if (tag == 0) {
                uint32_t ip = dec.decode_u32();
                uint16_t port = dec.decode_u16();
                msg.repair_addr = SocketAddr(ip, port);
            } else {
                // Skip IPv6 for now
                dec.skip(18);  // 16 bytes IP + 2 bytes port
            }
        }

        return msg;
    }
};

/**
 * VersionMismatch - Protocol version incompatible.
 */
struct VersionMismatch {
    static constexpr MessageType TYPE = MessageType::VersionMismatch;
    uint32_t offered;  // Version offered by upstairs

    static VersionMismatch decode(bincode::Decoder& dec) {
        return {dec.decode_u32()};
    }
};

// ============================================================================
// Metadata Messages
// ============================================================================

/**
 * RegionInfoPlease - Request region information.
 */
struct RegionInfoPlease {
    static constexpr MessageType TYPE = MessageType::RegionInfoPlease;

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
    }
};

/**
 * RegionInfo - Region definition response.
 */
struct RegionInfo {
    static constexpr MessageType TYPE = MessageType::RegionInfo;

    RegionDefinition region_def;

    static RegionInfo decode(bincode::Decoder& dec) {
        RegionInfo msg;
        msg.region_def.block_size = dec.decode_u32();
        msg.region_def.extent_size = dec.decode_u64();
        msg.region_def.uuid = dec.decode_uuid();
        msg.region_def.encrypted = dec.decode_bool();
        msg.region_def.extent_count = dec.decode_u64();
        return msg;
    }
};

// ============================================================================
// IO Operations
// ============================================================================

/**
 * Write - Write operation to downstairs.
 */
struct Write {
    static constexpr MessageType TYPE = MessageType::Write;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    std::vector<uint64_t> dependencies;
    uint64_t start_block;
    std::vector<BlockContext> contexts;
    // Note: Data follows after contexts in separate buffer

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
        enc.encode_uuid(upstairs_id);
        enc.encode_uuid(session_id);
        enc.encode_u64(job_id);

        // Encode dependencies
        enc.encode_vec<uint64_t>(dependencies, [&](uint64_t dep) {
            enc.encode_u64(dep);
        });

        enc.encode_u64(start_block);

        // Encode contexts
        enc.encode_vec<BlockContext>(contexts, [&](const BlockContext& ctx) {
            enc.encode_u64(ctx.hash);
            enc.encode_option<EncryptionContext>(ctx.encryption_ctx,
                [&](const EncryptionContext& ectx) {
                    enc.encode_encryption_context(ectx);
                });
        });
    }
};

/**
 * WriteAck - Acknowledgment of write operation.
 */
struct WriteAck {
    static constexpr MessageType TYPE = MessageType::WriteAck;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    Result<void> result;

    static WriteAck decode(bincode::Decoder& dec) {
        WriteAck msg;
        msg.upstairs_id = dec.decode_uuid();
        msg.session_id = dec.decode_uuid();
        msg.job_id = dec.decode_u64();

        // Decode Result<()>
        uint8_t result_tag = dec.decode_u8();
        if (result_tag == 0) {
            msg.result = Result<void>::ok();
        } else {
            uint32_t error = dec.decode_u32();
            msg.result = Result<void>::err(static_cast<CrucibleError>(error));
        }

        return msg;
    }
};

/**
 * ReadRequest - Read operation request.
 */
struct ReadRequest {
    static constexpr MessageType TYPE = MessageType::ReadRequest;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    std::vector<uint64_t> dependencies;
    uint64_t start_block;
    uint64_t count;  // Number of blocks

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
        enc.encode_uuid(upstairs_id);
        enc.encode_uuid(session_id);
        enc.encode_u64(job_id);

        enc.encode_vec<uint64_t>(dependencies, [&](uint64_t dep) {
            enc.encode_u64(dep);
        });

        enc.encode_u64(start_block);
        enc.encode_u64(count);
    }
};

/**
 * ReadResponse - Read operation response.
 */
struct ReadResponse {
    static constexpr MessageType TYPE = MessageType::ReadResponse;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    Result<std::vector<ReadBlockContext>> blocks;
    // Note: Data follows after header in separate buffer

    static ReadResponse decode(bincode::Decoder& dec) {
        ReadResponse msg;
        msg.upstairs_id = dec.decode_uuid();
        msg.session_id = dec.decode_uuid();
        msg.job_id = dec.decode_u64();

        // Decode Result<Vec<ReadBlockContext>>
        uint8_t result_tag = dec.decode_u8();
        if (result_tag == 0) {
            // Ok - decode vector of contexts
            uint64_t len = dec.decode_u64();
            std::vector<ReadBlockContext> contexts;
            contexts.reserve(len);

            for (uint64_t i = 0; i < len; i++) {
                ReadBlockContext ctx;
                uint32_t type_disc = dec.decode_u32();
                ctx.type = static_cast<ReadBlockType>(type_disc);

                if (ctx.type == ReadBlockType::Empty) {
                    // No additional data
                } else if (ctx.type == ReadBlockType::Encrypted) {
                    ctx.encryption_ctx = dec.decode_encryption_context();
                } else if (ctx.type == ReadBlockType::Unencrypted) {
                    ctx.hash = dec.decode_u64();
                }

                contexts.push_back(ctx);
            }

            msg.blocks = Result<std::vector<ReadBlockContext>>::ok(std::move(contexts));
        } else {
            // Err
            uint32_t error = dec.decode_u32();
            msg.blocks = Result<std::vector<ReadBlockContext>>::err(
                static_cast<CrucibleError>(error));
        }

        return msg;
    }
};

/**
 * Flush - Flush operation.
 */
struct Flush {
    static constexpr MessageType TYPE = MessageType::Flush;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    std::vector<uint64_t> dependencies;
    uint64_t flush_number;
    uint64_t gen_number;
    optional<uint64_t> snapshot_details;
    uint64_t extent_limit;

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
        enc.encode_uuid(upstairs_id);
        enc.encode_uuid(session_id);
        enc.encode_u64(job_id);

        enc.encode_vec<uint64_t>(dependencies, [&](uint64_t dep) {
            enc.encode_u64(dep);
        });

        enc.encode_u64(flush_number);
        enc.encode_u64(gen_number);

        enc.encode_option<uint64_t>(snapshot_details, [&](uint64_t snap) {
            enc.encode_u64(snap);
        });

        enc.encode_u64(extent_limit);
    }
};

/**
 * FlushAck - Flush acknowledgment.
 */
struct FlushAck {
    static constexpr MessageType TYPE = MessageType::FlushAck;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    Result<void> result;

    static FlushAck decode(bincode::Decoder& dec) {
        FlushAck msg;
        msg.upstairs_id = dec.decode_uuid();
        msg.session_id = dec.decode_uuid();
        msg.job_id = dec.decode_u64();

        uint8_t result_tag = dec.decode_u8();
        if (result_tag == 0) {
            msg.result = Result<void>::ok();
        } else {
            uint32_t error = dec.decode_u32();
            msg.result = Result<void>::err(static_cast<CrucibleError>(error));
        }

        return msg;
    }
};

/**
 * Discard - Discard (trim) operation.
 *
 * Tells downstairs to discard/deallocate blocks in the given range.
 * Used for TRIM/UNMAP operations.
 */
struct Discard {
    static constexpr MessageType TYPE = MessageType::Discard;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    std::vector<uint64_t> dependencies;
    uint64_t offset;      // Byte offset (must be block-aligned)
    uint64_t length;      // Length in bytes (must be block-aligned)

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
        enc.encode_uuid(upstairs_id);
        enc.encode_uuid(session_id);
        enc.encode_u64(job_id);

        enc.encode_vec<uint64_t>(dependencies, [&](uint64_t dep) {
            enc.encode_u64(dep);
        });

        enc.encode_u64(offset);
        enc.encode_u64(length);
    }
};

/**
 * DiscardAck - Discard acknowledgment.
 */
struct DiscardAck {
    static constexpr MessageType TYPE = MessageType::DiscardAck;

    Uuid upstairs_id;
    Uuid session_id;
    uint64_t job_id;
    Result<void> result;

    static DiscardAck decode(bincode::Decoder& dec) {
        DiscardAck msg;
        msg.upstairs_id = dec.decode_uuid();
        msg.session_id = dec.decode_uuid();
        msg.job_id = dec.decode_u64();

        uint8_t result_tag = dec.decode_u8();
        if (result_tag == 0) {
            msg.result = Result<void>::ok();
        } else {
            uint32_t error = dec.decode_u32();
            msg.result = Result<void>::err(static_cast<CrucibleError>(error));
        }

        return msg;
    }
};

// ============================================================================
// Control Messages
// ============================================================================

/**
 * Ruok - Health check request ("Are you OK?").
 */
struct Ruok {
    static constexpr MessageType TYPE = MessageType::Ruok;

    void encode(bincode::Encoder& enc) const {
        enc.encode_u32(static_cast<uint32_t>(TYPE));
    }
};

/**
 * Imok - Health check response ("I'm OK").
 */
struct Imok {
    static constexpr MessageType TYPE = MessageType::Imok;

    static Imok decode(bincode::Decoder& /*dec*/) {
        return Imok{};
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/**
 * Decode message type discriminant.
 */
inline MessageType decode_message_type(bincode::Decoder& dec) {
    uint32_t disc = dec.decode_u32();
    return static_cast<MessageType>(disc);
}

/**
 * Encode message to vector with length prefix.
 */
template<typename T>
std::vector<uint8_t> encode_message(const T& msg) {
    bincode::Encoder enc;
    msg.encode(enc);
    auto data = enc.take();

    // Add length prefix
    std::vector<uint8_t> frame;
    frame.reserve(4 + data.size());

    uint32_t length = data.size();
    frame.push_back(length & 0xFF);
    frame.push_back((length >> 8) & 0xFF);
    frame.push_back((length >> 16) & 0xFF);
    frame.push_back((length >> 24) & 0xFF);

    frame.insert(frame.end(), data.begin(), data.end());
    return frame;
}

/**
 * Decode message from vector (length prefix already removed).
 */
template<typename T>
T decode_message(const std::vector<uint8_t>& data) {
    bincode::Decoder dec(data);
    MessageType type = decode_message_type(dec);

    if (type != T::TYPE) {
        throw std::runtime_error("Message type mismatch");
    }

    return T::decode(dec);
}

} // namespace crucible

#endif // CRUCIBLE_MESSAGES_HH
