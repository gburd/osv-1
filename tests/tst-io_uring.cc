/*
 * Copyright (C) 2026 OSv Developers
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <osv/io_uring.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <assert.h>

/* Test helper to work with current io_uring implementation limitations */
struct test_ring {
    int fd;
    struct io_uring_params params;
    struct io_uring_sq_ring *sq_ring;
    struct io_uring_cq_ring *cq_ring;
    struct io_uring_sqe *sqes;
    size_t sq_size;
    size_t cq_size;
    size_t sqe_size;
};

static int test_ring_init(struct test_ring *ring, unsigned entries)
{
    memset(ring, 0, sizeof(*ring));

    ring->fd = sys_io_uring_setup(entries, &ring->params);
    if (ring->fd < 0) {
        return ring->fd;
    }

    /* Calculate mmap sizes */
    ring->sq_size = sizeof(struct io_uring_sq_ring) +
                    ring->params.sq_entries * sizeof(uint32_t);
    ring->cq_size = sizeof(struct io_uring_cq_ring) +
                    ring->params.cq_entries * sizeof(struct io_uring_cqe);
    ring->sqe_size = ring->params.sq_entries * sizeof(struct io_uring_sqe);

    /* Note: Current OSv io_uring implementation has incomplete mmap support.
     * The SQE array is not properly shared with userspace via mmap.
     * These mmaps will succeed but won't provide functional ring access.
     * Full io_uring functionality requires completing the mmap implementation.
     */

    /* Try to mmap SQ ring (offset 0) */
    ring->sq_ring = (struct io_uring_sq_ring*)mmap(NULL, ring->sq_size,
                                                     PROT_READ | PROT_WRITE,
                                                     MAP_SHARED, ring->fd, 0);
    if (ring->sq_ring == MAP_FAILED) {
        close(ring->fd);
        return -errno;
    }

    /* Try to mmap CQ ring (offset != 0) */
    ring->cq_ring = (struct io_uring_cq_ring*)mmap(NULL, ring->cq_size,
                                                     PROT_READ | PROT_WRITE,
                                                     MAP_SHARED, ring->fd, 0x8000000ULL);
    if (ring->cq_ring == MAP_FAILED) {
        munmap(ring->sq_ring, ring->sq_size);
        close(ring->fd);
        return -errno;
    }

    /* Try to mmap SQE array (offset 0x10000000) */
    ring->sqes = (struct io_uring_sqe*)mmap(NULL, ring->sqe_size,
                                             PROT_READ | PROT_WRITE,
                                             MAP_SHARED, ring->fd, 0x10000000ULL);
    if (ring->sqes == MAP_FAILED) {
        munmap(ring->cq_ring, ring->cq_size);
        munmap(ring->sq_ring, ring->sq_size);
        close(ring->fd);
        return -errno;
    }

    return 0;
}

static void test_ring_cleanup(struct test_ring *ring)
{
    if (ring->sqes && ring->sqes != MAP_FAILED) {
        munmap(ring->sqes, ring->sqe_size);
    }
    if (ring->sq_ring && ring->sq_ring != MAP_FAILED) {
        munmap(ring->sq_ring, ring->sq_size);
    }
    if (ring->cq_ring && ring->cq_ring != MAP_FAILED) {
        munmap(ring->cq_ring, ring->cq_size);
    }
    if (ring->fd >= 0) {
        close(ring->fd);
    }
}

static void test_io_uring_setup(void)
{
    printf("Testing io_uring_setup...\n");

    struct io_uring_params params = {};
    long fd = sys_io_uring_setup(32, &params);

    assert(fd >= 0);
    assert(params.sq_entries == 32);
    assert(params.cq_entries == 64);  /* Default is 2x SQ entries */

    close(fd);
    printf("  PASSED - setup syscall works\n");
}

static void test_io_uring_init(void)
{
    printf("Testing io_uring initialization...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Verify ring parameters were set correctly */
    assert(ring.params.sq_entries == 8);
    assert(ring.params.cq_entries == 16);

    /* Verify mmap succeeded (even if functionality is limited) */
    assert(ring.sq_ring != NULL && ring.sq_ring != MAP_FAILED);
    assert(ring.cq_ring != NULL && ring.cq_ring != MAP_FAILED);

    /* Verify ring metadata is initialized */
    assert(ring.sq_ring->ring_entries == 8);
    assert(ring.sq_ring->ring_mask == 7);
    assert(ring.cq_ring->ring_entries == 16);
    assert(ring.cq_ring->ring_mask == 15);

    test_ring_cleanup(&ring);
    printf("  PASSED - ring initialization works\n");
}

static void test_io_uring_enter_basic(void)
{
    printf("Testing io_uring_enter syscall...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Call io_uring_enter with no submissions
     * Note: This tests the syscall interface, but actual I/O requires
     * completing the mmap implementation for SQE submission.
     */
    ret = sys_io_uring_enter(ring.fd, 0, 0, 0, NULL, 0);
    assert(ret == 0);

    test_ring_cleanup(&ring);
    printf("  PASSED - enter syscall works\n");
}

static void test_io_uring_register_stub(void)
{
    printf("Testing io_uring_register syscall...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* io_uring_register is currently a stub returning ENOSYS */
    ret = sys_io_uring_register(ring.fd, 0, NULL, 0);
    assert(ret == -ENOSYS);

    test_ring_cleanup(&ring);
    printf("  PASSED - register syscall stub works\n");
}

static void test_io_uring_multiple_rings(void)
{
    printf("Testing multiple io_uring instances...\n");

    struct test_ring ring1, ring2;

    int ret1 = test_ring_init(&ring1, 8);
    assert(ret1 == 0);

    int ret2 = test_ring_init(&ring2, 16);
    assert(ret2 == 0);

    /* Verify both rings have correct parameters */
    assert(ring1.params.sq_entries == 8);
    assert(ring2.params.sq_entries == 16);
    assert(ring1.fd != ring2.fd);

    test_ring_cleanup(&ring1);
    test_ring_cleanup(&ring2);
    printf("  PASSED - multiple rings work\n");
}

static void test_io_uring_invalid_params(void)
{
    printf("Testing io_uring error handling...\n");

    struct io_uring_params params = {};

    /* Test entries too small */
    long fd = sys_io_uring_setup(0, &params);
    assert(fd == -EINVAL);

    /* Test entries too large */
    fd = sys_io_uring_setup(10000, &params);
    assert(fd == -EINVAL);

    /* Test NULL params */
    fd = sys_io_uring_setup(32, NULL);
    assert(fd == -EFAULT);

    printf("  PASSED - error handling works\n");
}

static void test_io_uring_fd_operations(void)
{
    printf("Testing io_uring file descriptor operations...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Verify FD is valid */
    assert(ring.fd >= 0);

    /* Verify FD can be closed (will be closed again by cleanup) */
    int fd_copy = dup(ring.fd);
    assert(fd_copy >= 0);
    close(fd_copy);

    test_ring_cleanup(&ring);
    printf("  PASSED - FD operations work\n");
}

static void test_io_uring_mmap_access(void)
{
    printf("Testing io_uring mmap access...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Verify SQE array is accessible */
    assert(ring.sqes != NULL && ring.sqes != MAP_FAILED);

    /* Write to first SQE */
    ring.sqes[0].opcode = IORING_OP_NOP;
    ring.sqes[0].user_data = 0x12345678;

    /* Verify we can read it back */
    assert(ring.sqes[0].opcode == IORING_OP_NOP);
    assert(ring.sqes[0].user_data == 0x12345678);

    /* Verify ring metadata is accessible and initialized */
    assert(ring.sq_ring->ring_entries == 8);
    assert(ring.sq_ring->ring_mask == 7);
    assert(ring.cq_ring->ring_entries == 16);
    assert(ring.cq_ring->ring_mask == 15);

    test_ring_cleanup(&ring);
    printf("  PASSED - mmap access works\n");
}

static void test_io_uring_nop_via_ring(void)
{
    printf("Testing io_uring NOP via ring buffers...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Submit a NOP operation via ring buffers */
    unsigned int tail = ring.sq_ring->tail;
    unsigned int index = tail & ring.sq_ring->ring_mask;

    /* Fill in the SQE */
    struct io_uring_sqe *sqe = &ring.sqes[index];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_NOP;
    sqe->user_data = 0xDEADBEEF;

    /* Update tail to submit */
    ring.sq_ring->tail = tail + 1;

    /* Call io_uring_enter to process */
    ret = sys_io_uring_enter(ring.fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    assert(ret == 0);

    /* Check completion */
    unsigned int cq_head = ring.cq_ring->head;
    unsigned int cq_tail = ring.cq_ring->tail;

    assert(cq_tail > cq_head);

    /* Read the completion */
    struct io_uring_cqe *cqe = &ring.cq_ring->cqes[cq_head & ring.cq_ring->ring_mask];
    assert(cqe->user_data == 0xDEADBEEF);
    assert(cqe->res == 0); /* NOP should succeed */

    /* Update head to consume */
    ring.cq_ring->head = cq_head + 1;

    test_ring_cleanup(&ring);
    printf("  PASSED - NOP via ring buffers works\n");
}

static void test_io_uring_file_io(void)
{
    printf("Testing io_uring file I/O...\n");

    struct test_ring ring;
    int ret = test_ring_init(&ring, 8);
    assert(ret == 0);

    /* Create a temporary file */
    const char *test_file = "/tmp/io_uring_test.txt";
    int test_fd = open(test_file, O_RDWR | O_CREAT | O_TRUNC, 0644);
    assert(test_fd >= 0);

    /* Write some data via io_uring */
    const char *test_data = "Hello io_uring!";
    size_t test_len = strlen(test_data);

    unsigned int tail = ring.sq_ring->tail;
    unsigned int index = tail & ring.sq_ring->ring_mask;

    struct io_uring_sqe *sqe = &ring.sqes[index];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_WRITE;
    sqe->fd = test_fd;
    sqe->addr = (uint64_t)test_data;
    sqe->len = test_len;
    sqe->off = 0;
    sqe->user_data = 0x1;

    ring.sq_ring->tail = tail + 1;

    ret = sys_io_uring_enter(ring.fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    assert(ret == 0);

    /* Check write completion */
    unsigned int cq_head = ring.cq_ring->head;
    unsigned int cq_tail = ring.cq_ring->tail;
    assert(cq_tail > cq_head);

    struct io_uring_cqe *cqe = &ring.cq_ring->cqes[cq_head & ring.cq_ring->ring_mask];
    assert(cqe->user_data == 0x1);
    assert(cqe->res == (int32_t)test_len);

    ring.cq_ring->head = cq_head + 1;

    /* Read back via io_uring */
    char read_buf[128] = {0};
    tail = ring.sq_ring->tail;
    index = tail & ring.sq_ring->ring_mask;

    sqe = &ring.sqes[index];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_READ;
    sqe->fd = test_fd;
    sqe->addr = (uint64_t)read_buf;
    sqe->len = test_len;
    sqe->off = 0;
    sqe->user_data = 0x2;

    ring.sq_ring->tail = tail + 1;

    ret = sys_io_uring_enter(ring.fd, 1, 1, IORING_ENTER_GETEVENTS, NULL, 0);
    assert(ret == 0);

    /* Check read completion */
    cq_head = ring.cq_ring->head;
    cq_tail = ring.cq_ring->tail;
    assert(cq_tail > cq_head);

    cqe = &ring.cq_ring->cqes[cq_head & ring.cq_ring->ring_mask];
    assert(cqe->user_data == 0x2);
    assert(cqe->res == (int32_t)test_len);

    ring.cq_ring->head = cq_head + 1;

    /* Verify data */
    assert(memcmp(read_buf, test_data, test_len) == 0);

    close(test_fd);
    unlink(test_file);
    test_ring_cleanup(&ring);
    printf("  PASSED - file I/O via ring buffers works\n");
}

int main(int argc, char **argv)
{
    printf("===========================================\n");
    printf("OSv io_uring Test Suite\n");
    printf("===========================================\n\n");

    test_io_uring_setup();
    test_io_uring_init();
    test_io_uring_enter_basic();
    test_io_uring_register_stub();
    test_io_uring_multiple_rings();
    test_io_uring_invalid_params();
    test_io_uring_fd_operations();

    printf("\nAdvanced tests (ring buffer access and I/O):\n");
    test_io_uring_mmap_access();
    test_io_uring_nop_via_ring();
    test_io_uring_file_io();

    printf("\n===========================================\n");
    printf("All io_uring tests PASSED!\n");
    printf("===========================================\n");
    return 0;
}
