/*
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef NVMEOF_CLIENT_HH
#define NVMEOF_CLIENT_HH

#include "drivers/nvmeof-connection.hh"
#include "drivers/nvmeof-pdu.hh"
#include "drivers/nvme-structs.h"

#include <osv/mutex.h>
#include <string>
#include <memory>
#include <cstdint>
#include <atomic>

namespace nvmeof {

/**
 * NVMe/TCP initiator client.
 *
 * Owns a single TCP Connection to an nvmet-tcp target and implements the
 * minimal NVMe/TCP path: ICReq/ICResp negotiation, Fabrics Connect for the
 * admin queue and one I/O queue, Identify Controller/Namespace, and
 * synchronous read/write/flush on a single namespace.
 *
 * Thread-safety: every *_sync() holds _io_mutex across the whole
 * command-submit-through-response-receive sequence.  The Connection's own
 * send_lock_/recv_lock_ are NOT sufficient on their own here: a read's
 * CapsuleResp could otherwise be consumed by another worker's recv_exact()
 * mid-sequence on the shared socket.  Serialising the full round-trip is
 * the simplest correct approach for a single I/O queue.
 */
class NvmeofClient {
public:
    /**
     * Create a client.  Does not connect; call connect() afterwards.
     *
     * @param host    Target host or IP
     * @param port    Target TCP port
     * @param subnqn  Subsystem NQN to connect to (required)
     * @param hostnqn Host NQN to present (must be non-empty)
     */
    NvmeofClient(const std::string& host, uint16_t port,
                 const std::string& subnqn, const std::string& hostnqn);

    ~NvmeofClient() = default;

    NvmeofClient(const NvmeofClient&) = delete;
    NvmeofClient& operator=(const NvmeofClient&) = delete;

    /**
     * TCP connect, ICReq/ICResp negotiation, and Fabrics Connect for the
     * admin queue (qid 0) and one I/O queue (qid 1).
     *
     * @throws ConnectionError / std::runtime_error on failure
     */
    void connect();

    /**
     * Identify the controller and namespace 1, computing block size and
     * block count.
     *
     * @throws ConnectionError / std::runtime_error on failure
     */
    void identify();

    /**
     * Synchronous read.
     *
     * @param offset_bytes Byte offset (must be block-aligned)
     * @param len_bytes    Byte length (must be a block multiple)
     * @param buf          Destination buffer
     * @return 0 on success, EIO/EINVAL on failure
     */
    int read_sync(uint64_t offset_bytes, uint32_t len_bytes, void* buf);

    /**
     * Synchronous write.
     *
     * @param offset_bytes Byte offset (must be block-aligned)
     * @param len_bytes    Byte length (must be a block multiple)
     * @param buf          Source buffer
     * @return 0 on success, EIO/EINVAL on failure
     */
    int write_sync(uint64_t offset_bytes, uint32_t len_bytes, const void* buf);

    /**
     * Synchronous flush of the namespace volatile write cache.
     *
     * @return 0 on success, EIO on failure
     */
    int flush_sync();

    /**
     * Tear down and re-establish the session after a transport error:
     * TCP reconnect, ICReq/ICResp negotiation, and Fabrics Connect for the
     * admin and I/O queues.  The namespace geometry is left unchanged (it is
     * fixed for the lifetime of the device).  Caller must ensure no other
     * command is in flight; the single-worker dispatcher guarantees this.
     *
     * @return true if the session is usable again, false on failure
     */
    bool reconnect();

    /** Total namespace size in bytes. */
    uint64_t total_size() const { return _block_count * _block_size; }

    /** Logical block size in bytes. */
    uint32_t get_block_size() const { return _block_size; }

    /** Whether the underlying connection is up. */
    bool is_connected() const { return _conn && _conn->is_connected(); }

private:
    /** Allocate a fresh command id (16-bit wrap is fine for sync ops). */
    u16 next_cid() { return static_cast<u16>(_cid_counter.fetch_add(1)); }

    /** ICReq/ICResp negotiation; stores _maxh2cdata. */
    void negotiate_connection();

    /** Fabrics Connect for the given queue id; captures cntlid on qid 0. */
    void fabrics_connect(u16 qid, u16 sqsize);

    /** Identify with the given CNS/nsid into buf (4096 bytes). */
    void identify_locked(u32 cns, u32 nsid, void* buf);

    /**
     * Build and send a CapsuleCmd PDU (64-byte SQE + optional in-capsule
     * data).  Caller must hold _io_mutex.
     */
    void send_capsule_cmd_locked(const void* sqe, const void* data,
                                 uint32_t data_len);

    /** Receive a CapsuleResp PDU and copy out the CQE.  Holds _io_mutex. */
    void recv_rsp_locked(nvme_cq_entry_t& cqe_out);

    /**
     * Receive C2HData PDUs (copying datal bytes at datao into buf) and the
     * terminating CapsuleResp, returning 0 on success or EIO.  Used for
     * reads and Identify.  Caller must hold _io_mutex.
     */
    int recv_data_and_completion(void* buf, uint32_t buf_len);

    /** Send the H2CData PDU(s) satisfying one R2T.  Caller holds _io_mutex. */
    void send_h2c_data(u16 cid, u16 ttag, u32 r2to, u32 r2tl, const void* buf,
                       uint32_t buf_len);

    /** Fill an SGL1 describing in-capsule data (type 0x0, offset subtype). */
    static void fill_incapsule_sgl(nvme_sgl_descriptor& sgl, uint32_t len);

    /** Fill an SGL1 describing a transport data block (type 0x5). */
    static void fill_transport_sgl(nvme_sgl_descriptor& sgl, uint32_t len);

    /** True if the CQE reports success (sct==0 && sc==0). */
    static bool cqe_ok(const nvme_cq_entry_t& cqe);

    std::string _host;
    uint16_t _port;
    std::string _subnqn;
    std::string _hostnqn;
    u8 _hostid[16];

    std::unique_ptr<Connection> _conn;
    std::atomic<uint16_t> _cid_counter{1};

    u16 _cntlid{0xffff};       // controller id from admin Connect response
    uint32_t _maxh2cdata{0};   // negotiated from ICResp (0 == no limit)
    uint8_t _cpda{0};          // controller PDU data alignment from ICResp
    uint32_t _block_size{0};
    uint64_t _block_count{0};

    /* Serialises a full command+response round-trip on the shared socket. */
    mutex _io_mutex;
};

} // namespace nvmeof

#endif // NVMEOF_CLIENT_HH
