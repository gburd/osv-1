/*
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * NVMe/TCP initiator protocol client.  Implements the minimal command set
 * needed for a block device: ICReq/ICResp negotiation, Fabrics Connect for
 * the admin and one I/O queue, Identify Controller/Namespace, and
 * synchronous read/write/flush.  Header and data digests are disabled.
 *
 * SGL conventions (NVMe-oF 1.1, matching the Linux nvme-tcp initiator):
 *   - In-capsule data (the Connect command's 1024-byte payload) is
 *     described by a Data Block descriptor (type 0x0) with the Offset
 *     subtype (0x1), addr=0, length=payload.
 *   - Bulk read/write data is described by a Transport SGL Data Block
 *     descriptor (type 0x5), addr=0, length=transfer.  The controller then
 *     pulls write data with R2T/H2CData and pushes read data with C2HData;
 *     bulk data is never placed in-capsule.
 * All wire fields are little-endian; OSv x86_64 is little-endian so no
 * byte-swapping is performed here.
 */

#include "drivers/nvmeof-client.hh"

#include <osv/debug.h>

#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <errno.h>

namespace nvmeof {

namespace {
constexpr uint32_t IDENTIFY_DATA_LEN = 4096;
constexpr u16 ADMIN_SQSIZE = 31;   // 0-based: 32 entries
constexpr u16 IO_SQSIZE    = 31;   // 0-based: 32 entries
} // namespace

NvmeofClient::NvmeofClient(const std::string& host, uint16_t port,
                           const std::string& subnqn,
                           const std::string& hostnqn)
    : _host(host), _port(port), _subnqn(subnqn), _hostnqn(hostnqn)
{
    // Derive a stable 16-byte host identifier from a fixed prefix; the
    // exact value is not significant to nvmet-tcp for a dynamic controller.
    static const u8 prefix[16] = {
        0x05, 0x71, 0x05, 0x71, 0x4e, 0x56, 0x4d, 0x65,
        0x6f, 0x54, 0x43, 0x50, 0x00, 0x00, 0x00, 0x01
    };
    memcpy(_hostid, prefix, sizeof(_hostid));
}

bool NvmeofClient::cqe_ok(const nvme_cq_entry_t& cqe)
{
    return cqe.sct == 0 && cqe.sc == 0;
}

void NvmeofClient::fill_incapsule_sgl(nvme_sgl_descriptor& sgl, uint32_t len)
{
    memset(&sgl, 0, sizeof(sgl));
    sgl.unkeyed.addr = 0;
    sgl.unkeyed.length = len;
    sgl.unkeyed.type = NVME_SGL_DATA_BLOCK_TYPE;     // 0x0
    sgl.unkeyed.subtype = NVME_SGL_OFFSET_SUBTYPE;   // 0x1 (in-capsule)
}

void NvmeofClient::fill_transport_sgl(nvme_sgl_descriptor& sgl, uint32_t len)
{
    memset(&sgl, 0, sizeof(sgl));
    sgl.unkeyed.addr = 0;
    sgl.unkeyed.length = len;
    sgl.unkeyed.type = NVME_SGL_TRANSPORT_DATA_BLOCK_TYPE;  // 0x5
    // Subtype 0xa marks a transport-specific descriptor; the Linux nvme-tcp
    // initiator sets this for its single transport SGL and nvmet-tcp keys off
    // it, so match the wire format rather than leaving the subtype zero.
    sgl.unkeyed.subtype = 0xa;
}

void NvmeofClient::connect()
{
    _conn.reset(new Connection(_host, _port));
    negotiate_connection();
    fabrics_connect(0, ADMIN_SQSIZE);   // admin queue
    fabrics_connect(1, IO_SQSIZE);      // single I/O queue
}

void NvmeofClient::negotiate_connection()
{
    nvme_tcp_icreq req{};
    req.hdr.pdu_type = NVME_TCP_ICREQ;
    req.hdr.flags = 0;
    req.hdr.hlen = sizeof(nvme_tcp_icreq);
    req.hdr.pdo = 0;
    req.hdr.plen = sizeof(nvme_tcp_icreq);
    req.pfv = 0;
    req.hpda = 0;
    req.digest_flags = 0;   // no header/data digest
    req.maxr2t = 0;         // one outstanding R2T

    _conn->send_exact(&req, sizeof(req));

    nvme_tcp_icresp resp{};
    _conn->recv_exact(&resp, sizeof(resp));

    if (resp.hdr.pdu_type != NVME_TCP_ICRESP) {
        throw std::runtime_error("nvmeof: unexpected PDU in ICResp");
    }
    if (resp.pfv != 0) {
        throw std::runtime_error("nvmeof: unsupported PDU format version");
    }
    if (resp.digest_flags & (NVME_TCP_F_HDGST | NVME_TCP_F_DDGST)) {
        throw std::runtime_error("nvmeof: target requires digests");
    }
    _maxh2cdata = resp.maxh2cdata;   // 0 == treat as unlimited
    _cpda = resp.cpda;               // controller PDU data alignment unit
}

void NvmeofClient::fabrics_connect(u16 qid, u16 sqsize)
{
    nvmeof_connect_cmd cmd{};
    cmd.opc = NVME_FABRICS_OPC;
    cmd.rsvd1 = 0x40;   // PSDT field = 01b (SGL) in bits 7:6 of byte 1
    cmd.cid = next_cid();
    cmd.fctype = NVME_FCTYPE_CONNECT;
    fill_incapsule_sgl(cmd.sgl1, sizeof(nvmeof_connect_data));
    cmd.recfmt = 0;
    cmd.qid = qid;
    cmd.sqsize = sqsize;
    cmd.cattr = 0;
    cmd.kato = 0;   // keep-alive disabled (no keepalive timer)

    nvmeof_connect_data data{};
    memcpy(data.hostid, _hostid, sizeof(_hostid));
    data.cntlid = (qid == 0) ? 0xffff : _cntlid;   // dynamic on admin
    strncpy(data.subnqn, _subnqn.c_str(), sizeof(data.subnqn) - 1);
    strncpy(data.hostnqn, _hostnqn.c_str(), sizeof(data.hostnqn) - 1);

    nvme_cq_entry_t cqe{};
    WITH_LOCK(_io_mutex) {
        send_capsule_cmd_locked(&cmd, &data, sizeof(data));
        recv_rsp_locked(cqe);
    }

    if (!cqe_ok(cqe)) {
        throw std::runtime_error("nvmeof: Fabrics Connect failed (qid " +
                                 std::to_string(qid) + ")");
    }
    if (qid == 0) {
        // The Connect response returns the controller id in DW0 bits 15:0.
        _cntlid = static_cast<u16>(cqe.cs & 0xffff);
    }
}

void NvmeofClient::identify()
{
    alignas(8) u8 ctlr[IDENTIFY_DATA_LEN];
    alignas(8) u8 ns[IDENTIFY_DATA_LEN];

    WITH_LOCK(_io_mutex) {
        identify_locked(0x1, 0, ctlr);    // identify controller (cns=1)
        identify_locked(0x0, 1, ns);      // identify namespace 1 (cns=0)
    }

    auto* idns = reinterpret_cast<nvme_identify_ns_t*>(ns);
    unsigned lbaf_index = idns->flbas & 0xf;
    unsigned lbads = idns->lbaf[lbaf_index].lbads;
    if (lbads < 9 || lbads > 20) {
        throw std::runtime_error("nvmeof: implausible LBA data size");
    }
    _block_size = 1u << lbads;
    _block_count = idns->nsze;
    if (_block_count == 0) {
        throw std::runtime_error("nvmeof: namespace reports zero blocks");
    }
}

void NvmeofClient::identify_locked(u32 cns, u32 nsid, void* buf)
{
    nvme_acmd_identify_t cmd{};
    cmd.common.opc = NVME_ACMD_IDENTIFY;
    cmd.common.psdt = 1;   // SGL for data transfer
    cmd.common.cid = next_cid();
    cmd.common.nsid = nsid;
    fill_transport_sgl(cmd.common.sgl1, IDENTIFY_DATA_LEN);
    cmd.cns = cns;

    send_capsule_cmd_locked(&cmd, nullptr, 0);
    if (recv_data_and_completion(buf, IDENTIFY_DATA_LEN) != 0) {
        throw std::runtime_error("nvmeof: Identify command failed");
    }
}

void NvmeofClient::send_capsule_cmd_locked(const void* sqe, const void* data,
                                           uint32_t data_len)
{
    nvme_tcp_cmd_pdu pdu{};
    pdu.hdr.pdu_type = NVME_TCP_CMD;
    pdu.hdr.flags = 0;
    pdu.hdr.hlen = sizeof(nvme_tcp_cmd_pdu);                 // 72
    // The controller advertises its required data alignment as cpda in the
    // ICResp: in-capsule data must begin at a (cpda+1)*4-byte boundary from
    // the PDU start.  With cpda==0 (the nvmet-tcp default) this collapses to
    // the SQE end (72); a larger cpda inserts pad bytes between the SQE and
    // the data, which the plen below accounts for.
    uint32_t pad = 0;
    if (data_len) {
        uint32_t align = (static_cast<uint32_t>(_cpda) + 1) * 4;
        uint32_t base = sizeof(nvme_tcp_cmd_pdu);
        uint32_t aligned = (base + align - 1) & ~(align - 1);
        pad = aligned - base;
    }
    pdu.hdr.pdo = data_len ? (sizeof(nvme_tcp_cmd_pdu) + pad) : 0;
    pdu.hdr.plen = sizeof(nvme_tcp_cmd_pdu) + pad + data_len;
    memcpy(pdu.sqe, sqe, sizeof(pdu.sqe));

    if (data_len) {
        if (pad) {
            // Emit the SQE header, the alignment padding, then the data as
            // one atomic message so concurrent senders cannot interleave.
            static const u8 zeros[16] = {0};
            // cpda is 4 bits on the wire, so pad is at most (15+1)*4-4 = 60
            // bytes; send it in <=16-byte chunks from a zero buffer.
            _conn->send_exact(&pdu, sizeof(pdu));
            uint32_t left = pad;
            while (left) {
                uint32_t chunk = std::min<uint32_t>(left, sizeof(zeros));
                _conn->send_exact(zeros, chunk);
                left -= chunk;
            }
            _conn->send_exact(data, data_len);
        } else {
            _conn->send_exact_with_data(&pdu, sizeof(pdu), data, data_len);
        }
    } else {
        _conn->send_exact(&pdu, sizeof(pdu));
    }
}

void NvmeofClient::recv_rsp_locked(nvme_cq_entry_t& cqe_out)
{
    nvme_tcp_hdr hdr{};
    _conn->recv_exact(&hdr, sizeof(hdr));
    if (hdr.pdu_type != NVME_TCP_RSP) {
        throw std::runtime_error("nvmeof: expected response capsule");
    }
    // Remaining bytes after the common header are the 16-byte CQE.
    _conn->recv_exact(&cqe_out, sizeof(cqe_out));
}

int NvmeofClient::recv_data_and_completion(void* buf, uint32_t buf_len)
{
    auto* out = static_cast<u8*>(buf);

    while (true) {
        nvme_tcp_hdr hdr{};
        _conn->recv_exact(&hdr, sizeof(hdr));

        if (hdr.pdu_type == NVME_TCP_C2H_DATA) {
            // Read the rest of the data PDU header (16 bytes), then datal
            // bytes of payload at datao within the transfer buffer.
            nvme_tcp_data_pdu dp{};
            dp.hdr = hdr;
            _conn->recv_exact(reinterpret_cast<u8*>(&dp) + sizeof(hdr),
                              sizeof(dp) - sizeof(hdr));

            // Bound the target-supplied offset/length against the caller's
            // buffer before copying: a malformed or hostile C2HData PDU must
            // not write past the transfer buffer.
            if (dp.datal > buf_len || dp.datao > buf_len - dp.datal) {
                throw std::runtime_error(
                    "nvmeof: C2HData datao/datal exceeds transfer buffer");
            }
            _conn->recv_exact(out + dp.datao, dp.datal);

            if (hdr.flags & NVME_TCP_F_DATA_SUCCESS) {
                // Last data PDU also signals successful completion; the
                // target sends no separate response capsule.
                return 0;
            }
            // Otherwise keep reading (more data PDUs or a response capsule).
            continue;
        }

        if (hdr.pdu_type == NVME_TCP_RSP) {
            nvme_cq_entry_t cqe{};
            _conn->recv_exact(&cqe, sizeof(cqe));
            return cqe_ok(cqe) ? 0 : EIO;
        }

        throw std::runtime_error("nvmeof: unexpected PDU during data phase");
    }
}

void NvmeofClient::send_h2c_data(u16 cid, u16 ttag, u32 r2to, u32 r2tl,
                                 const void* buf, uint32_t buf_len)
{
    // Bound the target-solicited offset/length against the write buffer: a
    // malformed R2T must not make us read past the caller's buffer.
    if (r2tl > buf_len || r2to > buf_len - r2tl) {
        throw std::runtime_error("nvmeof: R2T r2to/r2tl exceeds write buffer");
    }

    const auto* src = static_cast<const u8*>(buf);
    uint32_t chunk_cap = _maxh2cdata ? _maxh2cdata : r2tl;
    uint32_t sent = 0;

    while (sent < r2tl) {
        uint32_t chunk = std::min(chunk_cap, r2tl - sent);
        bool last = (sent + chunk) == r2tl;

        nvme_tcp_data_pdu dp{};
        dp.hdr.pdu_type = NVME_TCP_H2C_DATA;
        dp.hdr.flags = last ? NVME_TCP_F_DATA_LAST : 0;
        dp.hdr.hlen = sizeof(nvme_tcp_data_pdu);   // 24
        dp.hdr.pdo = sizeof(nvme_tcp_data_pdu);
        dp.hdr.plen = sizeof(nvme_tcp_data_pdu) + chunk;
        dp.cccid = cid;
        dp.ttag = ttag;
        dp.datao = r2to + sent;   // absolute offset within the transfer
        dp.datal = chunk;

        // src indexes the whole transfer buffer; r2to is the offset the
        // controller solicited within that transfer.
        _conn->send_exact_with_data(&dp, sizeof(dp), src + r2to + sent, chunk);
        sent += chunk;
    }
}

int NvmeofClient::read_sync(uint64_t offset_bytes, uint32_t len_bytes, void* buf)
{
    if (_block_size == 0 || len_bytes == 0 ||
        (offset_bytes % _block_size) != 0 || (len_bytes % _block_size) != 0) {
        return EINVAL;
    }

    nvme_command_rw_t cmd{};
    cmd.common.opc = NVME_CMD_READ;
    cmd.common.psdt = 1;
    cmd.common.cid = next_cid();
    cmd.common.nsid = 1;
    fill_transport_sgl(cmd.common.sgl1, len_bytes);
    cmd.slba = offset_bytes / _block_size;
    cmd.nlb = static_cast<u16>(len_bytes / _block_size - 1);

    try {
        WITH_LOCK(_io_mutex) {
            send_capsule_cmd_locked(&cmd, nullptr, 0);
            return recv_data_and_completion(buf, len_bytes);
        }
    } catch (const std::exception& e) {
        kprintf("nvmeof: read_sync exception: %s\n", e.what());
        return EIO;
    }
}

int NvmeofClient::write_sync(uint64_t offset_bytes, uint32_t len_bytes,
                             const void* buf)
{
    if (_block_size == 0 || len_bytes == 0 ||
        (offset_bytes % _block_size) != 0 || (len_bytes % _block_size) != 0) {
        return EINVAL;
    }

    nvme_command_rw_t cmd{};
    cmd.common.opc = NVME_CMD_WRITE;
    cmd.common.psdt = 1;
    cmd.common.cid = next_cid();
    cmd.common.nsid = 1;
    fill_transport_sgl(cmd.common.sgl1, len_bytes);
    cmd.slba = offset_bytes / _block_size;
    cmd.nlb = static_cast<u16>(len_bytes / _block_size - 1);

    try {
        WITH_LOCK(_io_mutex) {
            send_capsule_cmd_locked(&cmd, nullptr, 0);
            // The controller solicits the write data with one or more R2T
            // PDUs; reply to each with H2CData until the response capsule.
            while (true) {
                nvme_tcp_hdr hdr{};
                _conn->recv_exact(&hdr, sizeof(hdr));

                if (hdr.pdu_type == NVME_TCP_R2T) {
                    nvme_tcp_r2t_pdu r2t{};
                    r2t.hdr = hdr;
                    _conn->recv_exact(reinterpret_cast<u8*>(&r2t) + sizeof(hdr),
                                      sizeof(r2t) - sizeof(hdr));
                    send_h2c_data(cmd.common.cid, r2t.ttag, r2t.r2to,
                                  r2t.r2tl, buf, len_bytes);
                    continue;
                }
                if (hdr.pdu_type == NVME_TCP_RSP) {
                    nvme_cq_entry_t cqe{};
                    _conn->recv_exact(&cqe, sizeof(cqe));
                    return cqe_ok(cqe) ? 0 : EIO;
                }
                throw std::runtime_error("nvmeof: unexpected PDU during write");
            }
        }
    } catch (const std::exception& e) {
        kprintf("nvmeof: write_sync exception: %s\n", e.what());
        return EIO;
    }
}

int NvmeofClient::flush_sync()
{
    nvme_command_rw_t cmd{};
    cmd.common.opc = NVME_CMD_FLUSH;
    cmd.common.psdt = 1;
    cmd.common.cid = next_cid();
    cmd.common.nsid = 1;
    // Flush transfers no data; advertise a zero-length transport SGL.
    fill_transport_sgl(cmd.common.sgl1, 0);

    nvme_cq_entry_t cqe{};
    try {
        WITH_LOCK(_io_mutex) {
            send_capsule_cmd_locked(&cmd, nullptr, 0);
            recv_rsp_locked(cqe);
        }
    } catch (const std::exception& e) {
        kprintf("nvmeof: flush_sync exception: %s\n", e.what());
        return EIO;
    }
    return cqe_ok(cqe) ? 0 : EIO;
}

bool NvmeofClient::reconnect()
{
    // A transport error tears down the controller's queues, so a fresh TCP
    // socket alone is not enough -- the whole session (ICReq/ICResp plus
    // Fabrics Connect for both queues) has to be rebuilt.  cntlid resets to
    // dynamic so the admin Connect allocates a new controller.  Namespace
    // geometry is fixed for the device's lifetime and is left untouched.
    try {
        _cntlid = 0xffff;
        _conn.reset(new Connection(_host, _port));
        negotiate_connection();
        fabrics_connect(0, ADMIN_SQSIZE);
        fabrics_connect(1, IO_SQSIZE);
        return true;
    } catch (const std::exception& e) {
        kprintf("nvmeof: reconnect failed: %s\n", e.what());
        return false;
    }
}

} // namespace nvmeof
