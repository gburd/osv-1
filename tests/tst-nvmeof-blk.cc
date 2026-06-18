/*
 * Copyright (C) 2026 OSv Authors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/*
 * NVMe/TCP initiator block device validation: exercise /dev/nvmeof0
 * directly with the OSv block-device file descriptor interface.
 *
 * The test:
 *   1. Opens /dev/nvmeof0 (must be present; build with
 *      conf_drivers_profile=nvmeof and pass --nvmeof=host:port plus
 *      --nvmeof-subnqn=... to run.py).
 *   2. Verifies the device size and reports it.
 *   3. Performs an aligned 4 KiB write/flush/read/verify at offset 0.
 *   4. Performs the same round-trip at end-of-disk.
 *   5. Performs a 64 KiB sequential write/flush/read mid-disk.
 *   6. Reports throughput numbers.
 *
 * Run:
 *   ./scripts/run.py -k --arch=x86_64 -m 2048 -c1 \
 *     --nvmeof=HOST:4420 --nvmeof-subnqn=nqn.2026-01.org.osv:target0 \
 *     -e "tests/tst-nvmeof-blk.so"
 *
 * Without a reachable nvmet-tcp target, the boot path will print
 * "boot will continue, but /dev/nvmeofN will not be available", and this
 * test will SKIP.
 */

#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <fcntl.h>
#include <linux/fs.h>          /* BLKGETSIZE64 */
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

constexpr const char *DEV        = "/dev/nvmeof0";
constexpr size_t      LBA_SIZE = 4096;
constexpr size_t      BIG_IO_SIZE = 65536;          /* 16 blocks */
constexpr uint8_t     PATTERN_A  = 0xa5;
constexpr uint8_t     PATTERN_B  = 0x5a;

int  tests_run    = 0;
int  tests_passed = 0;
int  tests_failed = 0;

#define PASS(fmt, ...) do {                                  \
    tests_run++; tests_passed++;                              \
    printf("  PASS  " fmt "\n", ##__VA_ARGS__);               \
} while (0)

#define FAIL(fmt, ...) do {                                   \
    tests_run++; tests_failed++;                              \
    printf("  FAIL  " fmt "\n", ##__VA_ARGS__);               \
} while (0)

void *aligned_alloc_io(size_t size)
{
    void *p = nullptr;
    if (posix_memalign(&p, LBA_SIZE, size) != 0)
        return nullptr;
    return p;
}

bool check_buffer(const uint8_t *buf, size_t size, uint8_t expected)
{
    for (size_t i = 0; i < size; i++) {
        if (buf[i] != expected)
            return false;
    }
    return true;
}

bool roundtrip_block(int fd, off_t offset, uint8_t pattern,
                     size_t size, const char *label)
{
    uint8_t *wbuf = static_cast<uint8_t *>(aligned_alloc_io(size));
    uint8_t *rbuf = static_cast<uint8_t *>(aligned_alloc_io(size));
    if (!wbuf || !rbuf) {
        FAIL("%s: posix_memalign failed", label);
        free(wbuf); free(rbuf);
        return false;
    }
    memset(wbuf, pattern, size);
    memset(rbuf, 0, size);

    auto t0 = std::chrono::high_resolution_clock::now();

    ssize_t n = pwrite(fd, wbuf, size, offset);
    if (n != static_cast<ssize_t>(size)) {
        FAIL("%s: pwrite returned %zd (errno=%d %s)",
             label, n, errno, strerror(errno));
        free(wbuf); free(rbuf);
        return false;
    }
    if (fsync(fd) != 0) {
        FAIL("%s: fsync failed (errno=%d %s)", label, errno, strerror(errno));
        free(wbuf); free(rbuf);
        return false;
    }

    n = pread(fd, rbuf, size, offset);
    if (n != static_cast<ssize_t>(size)) {
        FAIL("%s: pread returned %zd (errno=%d %s)",
             label, n, errno, strerror(errno));
        free(wbuf); free(rbuf);
        return false;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    double secs = std::chrono::duration<double>(t1 - t0).count();
    double mbs = (2.0 * size / (1024 * 1024)) / secs;

    if (!check_buffer(rbuf, size, pattern)) {
        FAIL("%s: data mismatch after read-back at offset %lld",
             label, (long long)offset);
        free(wbuf); free(rbuf);
        return false;
    }

    PASS("%s: %zu B @ offset %lld round-trip OK in %.2f ms (%.1f MB/s w+r)",
         label, size, (long long)offset, secs * 1000.0, mbs);
    free(wbuf); free(rbuf);
    return true;
}

} /* anonymous namespace */

int main()
{
    printf("=== NVMe/TCP block device test ===\n\n");

    int fd = open(DEV, O_RDWR);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENODEV) {
            printf("SKIP: %s does not exist (boot without --nvmeof= ?)\n", DEV);
            return 0;
        }
        printf("FAIL: open(%s) failed: %s\n", DEV, strerror(errno));
        return 1;
    }
    PASS("open(%s) succeeded (fd=%d)", DEV, fd);

    /*
     * fstat on a block device reports 0 size on OSv; use BLKGETSIZE64 to
     * query the device size in bytes.
     */
    uint64_t size = 0;
    if (ioctl(fd, BLKGETSIZE64, &size) != 0 || size == 0) {
        FAIL("BLKGETSIZE64 ioctl returned 0/error: %s", strerror(errno));
        close(fd);
        return 1;
    }
    PASS("device size: %llu bytes (%.1f MiB)",
         (unsigned long long)size, size / (1024.0 * 1024.0));

    /* Test 1: 4 KiB at offset 0. */
    roundtrip_block(fd, 0, PATTERN_A, LBA_SIZE, "4 KiB @ 0");

    /* Test 2: 4 KiB at end of disk. */
    off_t last_block = size - LBA_SIZE;
    roundtrip_block(fd, last_block, PATTERN_B, LBA_SIZE, "4 KiB @ end");

    /* Test 3: 64 KiB at mid-disk. */
    off_t mid = (size / 2) & ~(off_t)(LBA_SIZE - 1);
    roundtrip_block(fd, mid, PATTERN_A, BIG_IO_SIZE, "64 KiB @ mid");

    /* Test 4: 64 KiB byte-order pattern to detect any block reordering. */
    {
        const size_t N = BIG_IO_SIZE;
        uint8_t *wbuf = static_cast<uint8_t *>(aligned_alloc_io(N));
        uint8_t *rbuf = static_cast<uint8_t *>(aligned_alloc_io(N));
        if (!wbuf || !rbuf) {
            FAIL("byte-order pattern: alloc failed");
        } else {
            for (size_t i = 0; i < N; i++) {
                wbuf[i] = static_cast<uint8_t>(i ^ (i >> 8) ^ 0x37);
            }
            memset(rbuf, 0, N);
            ssize_t n = pwrite(fd, wbuf, N, 0);
            bool ok = (n == static_cast<ssize_t>(N)) && (fsync(fd) == 0);
            n = ok ? pread(fd, rbuf, N, 0) : 0;
            if (!ok || n != static_cast<ssize_t>(N) ||
                memcmp(wbuf, rbuf, N) != 0) {
                FAIL("byte-order pattern: write+read+verify failed (errno=%d)",
                     errno);
            } else {
                PASS("byte-order pattern: 64 KiB round-trip preserves order");
            }
        }
        free(wbuf); free(rbuf);
    }

    /* Test 5: 1 MiB sequential write/read throughput. */
    {
        const size_t N = 1024 * 1024;
        const int iters = 4;
        uint8_t *wbuf = static_cast<uint8_t *>(aligned_alloc_io(N));
        uint8_t *rbuf = static_cast<uint8_t *>(aligned_alloc_io(N));
        if (!wbuf || !rbuf) {
            FAIL("1 MiB throughput: alloc failed");
        } else {
            memset(wbuf, 0xC3, N);
            auto t0 = std::chrono::high_resolution_clock::now();
            bool ok = true;
            for (int i = 0; i < iters; i++) {
                off_t off = static_cast<off_t>(i) * N;
                if (pwrite(fd, wbuf, N, off) != static_cast<ssize_t>(N)) {
                    ok = false; break;
                }
            }
            ok = ok && fsync(fd) == 0;
            auto t1 = std::chrono::high_resolution_clock::now();
            double w_secs = std::chrono::duration<double>(t1 - t0).count();
            double w_mbs = (iters * N / (1024.0 * 1024.0)) / w_secs;

            auto r0 = std::chrono::high_resolution_clock::now();
            for (int i = 0; ok && i < iters; i++) {
                off_t off = static_cast<off_t>(i) * N;
                if (pread(fd, rbuf, N, off) != static_cast<ssize_t>(N) ||
                    memcmp(wbuf, rbuf, N) != 0) {
                    ok = false; break;
                }
            }
            auto r1 = std::chrono::high_resolution_clock::now();
            double r_secs = std::chrono::duration<double>(r1 - r0).count();
            double r_mbs = (iters * N / (1024.0 * 1024.0)) / r_secs;

            if (ok) {
                PASS("throughput: %d x 1 MiB write %.1f MB/s, read %.1f MB/s",
                     iters, w_mbs, r_mbs);
            } else {
                FAIL("throughput test failed at iteration");
            }
        }
        free(wbuf); free(rbuf);
    }

    close(fd);

    printf("\n=== Results: %d/%d passed (%d failed) ===\n",
           tests_passed, tests_run, tests_failed);
    return tests_failed == 0 ? 0 : 1;
}
