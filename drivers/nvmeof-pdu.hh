/*
 * NVMe-over-TCP (NVMe/TCP) PDU and Fabrics wire structures for OSv
 *
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Wire layouts follow NVMe-oF 1.1 / TP 8000 (NVMe/TCP transport).  Every
 * struct that crosses the wire is __attribute__((packed)) and carries a
 * static_assert on its size.  All multi-byte fields are little-endian; OSv
 * x86_64 is little-endian so no byte-swapping is required (an aarch64 or
 * big-endian port would need explicit conversions here).
 */

#ifndef NVMEOF_PDU_HH
#define NVMEOF_PDU_HH

#include "drivers/nvme-structs.h"
#include <cstdint>

namespace nvmeof {

// NVMe/TCP PDU type codes (NVMe-oF 1.1, Figure "PDU Types").
enum nvme_tcp_pdu_type {
    NVME_TCP_ICREQ        = 0x00,  // initialize connection request
    NVME_TCP_ICRESP       = 0x01,  // initialize connection response
    NVME_TCP_H2C_TERM     = 0x02,  // host -> controller termination request
    NVME_TCP_C2H_TERM     = 0x03,  // controller -> host termination request
    NVME_TCP_CMD          = 0x04,  // command capsule
    NVME_TCP_RSP          = 0x05,  // response capsule
    NVME_TCP_H2C_DATA     = 0x06,  // host -> controller data transfer
    NVME_TCP_C2H_DATA     = 0x07,  // controller -> host data transfer
    NVME_TCP_R2T          = 0x09,  // ready to transfer
};

// Common-header (CH) FLAGS field bits.  HDGSTF/DDGSTF select header/data
// digests (we keep both off).  LAST/SUCCESS apply to the data PDUs.
enum nvme_tcp_hdr_flags {
    NVME_TCP_F_HDGST      = 0x01,  // header digest present
    NVME_TCP_F_DDGST      = 0x02,  // data digest present
    NVME_TCP_F_DATA_LAST  = 0x04,  // last data PDU of this transfer
    NVME_TCP_F_DATA_SUCCESS = 0x08,  // C2HData: command completed, no RSP capsule
};

// Fabrics command opcode and command types (NVMe-oF 1.1).
enum {
    NVME_FABRICS_OPC      = 0x7f,  // Fabrics command opcode (in SQE.opc)
    NVME_FCTYPE_PROP_SET  = 0x00,  // property set (unused here)
    NVME_FCTYPE_CONNECT   = 0x01,  // connect
    NVME_FCTYPE_PROP_GET  = 0x04,  // property get (unused here)
};

/*
 * NVMe/TCP common PDU header (8 bytes).  plen is the total PDU length in
 * bytes including this header, the PDU-specific header, any header/data
 * digests, padding, and the data payload.
 */
struct __attribute__((packed)) nvme_tcp_hdr {
    u8  pdu_type;   // one of nvme_tcp_pdu_type
    u8  flags;      // nvme_tcp_hdr_flags
    u8  hlen;       // length of header (CH + PSH), no digests
    u8  pdo;        // PDU data offset (0 if no data)
    u32 plen;       // total PDU length (little-endian)
};
static_assert(sizeof(nvme_tcp_hdr) == 8, "nvme_tcp_hdr must be 8 bytes");

/*
 * ICReq PDU (128 bytes total).  pfv=0 (format version 0), hpda=0 (no host
 * page-data alignment), digest_flags=0 (digests off), maxr2t=0 (host
 * accepts one outstanding R2T at a time).
 */
struct __attribute__((packed)) nvme_tcp_icreq {
    nvme_tcp_hdr hdr;
    u16 pfv;            // PDU format version (0)
    u8  hpda;           // host PDU data alignment (0)
    u8  digest_flags;   // bit0 HDGST_ENABLE, bit1 DDGST_ENABLE
    u32 maxr2t;         // max outstanding R2T (0 == 1)
    u8  rsvd[112];
};
static_assert(sizeof(nvme_tcp_icreq) == 128, "ICReq must be 128 bytes");

/*
 * ICResp PDU (128 bytes total).  maxh2cdata caps the data length the host
 * may place in a single H2CData PDU.
 */
struct __attribute__((packed)) nvme_tcp_icresp {
    nvme_tcp_hdr hdr;
    u16 pfv;            // PDU format version (0)
    u8  cpda;           // controller PDU data alignment
    u8  digest_flags;   // negotiated digest flags
    u32 maxh2cdata;     // max H2CData PDU data length the host may send
    u8  rsvd[112];
};
static_assert(sizeof(nvme_tcp_icresp) == 128, "ICResp must be 128 bytes");

/*
 * Command capsule PDU header: common header (8) + 64-byte SQE (72 total).
 * In-capsule data (e.g. the 1024-byte Connect data) follows at pdo=72.
 * The SQE is carried as a raw 64-byte buffer so both nvme_sq_entry_t and
 * the Fabrics command structures below can be memcpy'd into it.
 */
struct __attribute__((packed)) nvme_tcp_cmd_pdu {
    nvme_tcp_hdr hdr;
    u8 sqe[64];
};
static_assert(sizeof(nvme_tcp_cmd_pdu) == 72, "CapsuleCmd header must be 72 bytes");

/*
 * Response capsule PDU: common header (8) + 16-byte CQE (24 total).
 */
struct __attribute__((packed)) nvme_tcp_rsp_pdu {
    nvme_tcp_hdr hdr;
    nvme_cq_entry_t cqe;
};
static_assert(sizeof(nvme_tcp_rsp_pdu) == 24, "CapsuleResp must be 24 bytes");

/*
 * Data transfer PDU header (H2CData and C2HData share this layout, 24
 * bytes before the data payload).  For H2CData the second field is the
 * TTAG echoed from the soliciting R2T; for C2HData it is reserved.
 */
struct __attribute__((packed)) nvme_tcp_data_pdu {
    nvme_tcp_hdr hdr;
    u16 cccid;      // command capsule CID (echoes the SQE cid)
    u16 ttag;       // transfer tag (H2CData); reserved for C2HData
    u32 datao;      // data offset within the command's transfer
    u32 datal;      // data length carried by this PDU
    u32 rsvd;
};
static_assert(sizeof(nvme_tcp_data_pdu) == 24, "Data PDU header must be 24 bytes");

/*
 * R2T PDU (24 bytes): the controller solicits r2tl bytes starting at
 * r2to; the host replies with H2CData PDU(s) echoing ttag.
 */
struct __attribute__((packed)) nvme_tcp_r2t_pdu {
    nvme_tcp_hdr hdr;
    u16 cccid;
    u16 ttag;
    u32 r2to;       // requested data offset
    u32 r2tl;       // requested data length
    u32 rsvd;
};
static_assert(sizeof(nvme_tcp_r2t_pdu) == 24, "R2T must be 24 bytes");

/*
 * Fabrics Connect command (64-byte SQE).  Layout per NVMe-oF 1.1:
 *   opc=7Fh, fctype=01h, SGL1 describes the 1024-byte in-capsule Connect
 *   data, recfmt=0, qid selects the queue, sqsize is the 0-based queue
 *   depth, kato is the keep-alive timeout (admin queue only).
 */
struct __attribute__((packed)) nvmeof_connect_cmd {
    u8  opc;            // NVME_FABRICS_OPC
    u8  rsvd1;
    u16 cid;
    u8  fctype;         // NVME_FCTYPE_CONNECT
    u8  rsvd2[19];
    nvme_sgl_descriptor sgl1;   // 16 bytes: in-capsule data descriptor
    u16 recfmt;         // record format (0)
    u16 qid;            // queue id (0 = admin)
    u16 sqsize;         // submission queue size (0-based)
    u8  cattr;          // connect attributes (0)
    u8  rsvd3;
    u32 kato;           // keep-alive timeout in ms (0 = disabled)
    u8  rsvd4[12];
};
static_assert(sizeof(nvmeof_connect_cmd) == 64, "Connect command must be 64 bytes");

/*
 * Fabrics Connect data (1024-byte in-capsule payload).  cntlid is 0xFFFF
 * for a dynamic controller on the admin Connect, and the controller id
 * returned by that Connect on each I/O-queue Connect.
 */
struct __attribute__((packed)) nvmeof_connect_data {
    u8   hostid[16];
    u16  cntlid;
    u8   rsvd[238];
    char subnqn[256];
    char hostnqn[256];
    u8   rsvd2[256];
};
static_assert(sizeof(nvmeof_connect_data) == 1024, "Connect data must be 1024 bytes");

} // namespace nvmeof

#endif // NVMEOF_PDU_HH
