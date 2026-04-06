/*
 * Copyright (C) 2026 OSv Developers
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef OSV_IO_URING_H
#define OSV_IO_URING_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* io_uring operation codes */
enum {
    IORING_OP_NOP,
    IORING_OP_READV,
    IORING_OP_WRITEV,
    IORING_OP_FSYNC,
    IORING_OP_READ_FIXED,
    IORING_OP_WRITE_FIXED,
    IORING_OP_POLL_ADD,
    IORING_OP_POLL_REMOVE,
    IORING_OP_SYNC_FILE_RANGE,
    IORING_OP_SENDMSG,
    IORING_OP_RECVMSG,
    IORING_OP_TIMEOUT,
    IORING_OP_TIMEOUT_REMOVE,
    IORING_OP_ACCEPT,
    IORING_OP_ASYNC_CANCEL,
    IORING_OP_LINK_TIMEOUT,
    IORING_OP_CONNECT,
    IORING_OP_FALLOCATE,
    IORING_OP_OPENAT,
    IORING_OP_CLOSE,
    IORING_OP_FILES_UPDATE,
    IORING_OP_STATX,
    IORING_OP_READ,
    IORING_OP_WRITE,
    IORING_OP_FADVISE,
    IORING_OP_MADVISE,
    IORING_OP_SEND,
    IORING_OP_RECV,
    IORING_OP_OPENAT2,
    IORING_OP_EPOLL_CTL,
};

/* io_uring setup flags */
#define IORING_SETUP_IOPOLL     (1U << 0)
#define IORING_SETUP_SQPOLL     (1U << 1)
#define IORING_SETUP_SQ_AFF     (1U << 2)
#define IORING_SETUP_CQSIZE     (1U << 3)
#define IORING_SETUP_CLAMP      (1U << 4)
#define IORING_SETUP_ATTACH_WQ  (1U << 5)

/* io_uring enter flags */
#define IORING_ENTER_GETEVENTS  (1U << 0)
#define IORING_ENTER_SQ_WAKEUP  (1U << 1)

/* Submission Queue Entry */
struct io_uring_sqe {
    uint8_t opcode;         /* operation code */
    uint8_t flags;          /* IOSQE_ flags */
    uint16_t ioprio;        /* ioprio for the request */
    int32_t fd;             /* file descriptor */
    union {
        uint64_t off;       /* offset into file */
        uint64_t addr2;
    };
    union {
        uint64_t addr;      /* pointer to buffer or iovecs */
        uint64_t splice_off_in;
    };
    uint32_t len;           /* buffer size or number of iovecs */
    union {
        uint32_t rw_flags;
        uint32_t fsync_flags;
        uint16_t poll_events;
        uint32_t sync_range_flags;
        uint32_t msg_flags;
        uint32_t timeout_flags;
        uint32_t accept_flags;
        uint32_t cancel_flags;
        uint32_t open_flags;
        uint32_t statx_flags;
        uint32_t fadvise_advice;
        uint32_t splice_flags;
    };
    uint64_t user_data;     /* data to be passed back at completion time */
    union {
        struct {
            /* index into fixed buffers, if used */
            union {
                /* index into fixed buffers, if used */
                uint16_t buf_index;
                /* for grouped buffer selection */
                uint16_t buf_group;
            };
            /* personality to use, if used */
            uint16_t personality;
            int32_t splice_fd_in;
        };
        uint64_t __pad2[3];
    };
};

/* Completion Queue Entry */
struct io_uring_cqe {
    uint64_t user_data;     /* sqe->data submission passed back */
    int32_t res;            /* result code for this event */
    uint32_t flags;
};

/* io_uring submission queue ring */
struct io_uring_sq_ring {
    uint32_t head;
    uint32_t tail;
    uint32_t ring_mask;
    uint32_t ring_entries;
    uint32_t flags;
    uint32_t dropped;
    uint32_t array[];
};

/* io_uring completion queue ring */
struct io_uring_cq_ring {
    uint32_t head;
    uint32_t tail;
    uint32_t ring_mask;
    uint32_t ring_entries;
    uint32_t overflow;
    struct io_uring_cqe cqes[];
};

/* io_uring setup parameters */
struct io_uring_params {
    uint32_t sq_entries;
    uint32_t cq_entries;
    uint32_t flags;
    uint32_t sq_thread_cpu;
    uint32_t sq_thread_idle;
    uint32_t features;
    uint32_t resv[4];
};

/* io_uring register opcodes */
enum {
    IORING_REGISTER_BUFFERS,
    IORING_UNREGISTER_BUFFERS,
    IORING_REGISTER_FILES,
    IORING_UNREGISTER_FILES,
    IORING_REGISTER_EVENTFD,
    IORING_UNREGISTER_EVENTFD,
    IORING_REGISTER_FILES_UPDATE,
    IORING_REGISTER_EVENTFD_ASYNC,
    IORING_REGISTER_PROBE,
    IORING_REGISTER_PERSONALITY,
    IORING_UNREGISTER_PERSONALITY,
};

/* Forward declarations for internal structures */
struct io_uring_ctx;

/* System call prototypes */
long sys_io_uring_setup(unsigned entries, struct io_uring_params *params);
int sys_io_uring_enter(int fd, unsigned to_submit, unsigned min_complete,
                       unsigned flags, const void *sig, size_t sigsz);
int sys_io_uring_register(int fd, unsigned opcode, void *arg, unsigned nr_args);

#ifdef __cplusplus
}
#endif

#endif /* OSV_IO_URING_H */
