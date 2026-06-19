/*
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/*
 * NVMe/TCP initiator sustained-load correctness test, NO filesystem.
 *
 * Writes the entire /dev/nvmeof0 device with a deterministic, position-
 * dependent payload using a rotating set of I/O sizes, then reads the whole
 * device back and verifies every byte.  Unlike tst-nvmeof-blk (a handful of
 * isolated round-trips), this drives sustained back-to-back volume so a
 * transport bug that only manifests under load -- command-id wrap, PDU
 * mis-framing across many transfers, an offset/length error at a particular
 * size class -- is exposed without ZFS in the path.  This is the
 * discriminator: if this passes but the RAID-Z load test corrupts, the bug
 * is at the ZFS layer, not in the NVMe/TCP transport.
 *
 * Run:
 *   ./scripts/run.py -k --arch=x86_64 --vnc none -m 2048 -c1 \
 *     --nvmeof0=HOST:4420 --nvmeof0-subnqn=nqn... \
 *     -e "tests/tst-nvmeof-load.so"
 */

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <fcntl.h>
#include <linux/fs.h>          /* BLKGETSIZE64 */
#include <sys/ioctl.h>
#include <unistd.h>

namespace {

constexpr const char *DEV = "/dev/nvmeof0";
constexpr size_t LBA_SIZE = 4096;

int tests_run = 0, tests_passed = 0, tests_failed = 0;

#define PASS(fmt, ...) do { tests_run++; tests_passed++; \
    printf("  PASS  " fmt "\n", ##__VA_ARGS__); } while (0)
#define FAIL(fmt, ...) do { tests_run++; tests_failed++; \
    printf("  FAIL  " fmt "\n", ##__VA_ARGS__); } while (0)

/* Same generator family as the RAID-Z load test, position-dependent so a
 * block read back from the wrong LBA is detected. */
static inline uint8_t payload_byte(uint64_t i)
{
    return static_cast<uint8_t>((i * 31u + (i >> 11)) ^ 0xA7);
}

void *aligned_io(size_t n)
{
    void *p = nullptr;
    return posix_memalign(&p, LBA_SIZE, n) == 0 ? p : nullptr;
}

} /* anonymous namespace */

int main()
{
    printf("=== NVMe/TCP sustained-load correctness test (no FS) ===\n\n");

    int fd = open(DEV, O_RDWR);
    if (fd < 0) {
        if (errno == ENOENT || errno == ENODEV) {
            printf("SKIP: %s absent (boot without --nvmeof0= ?)\n", DEV);
            return 0;
        }
        printf("FAIL: open(%s): %s\n", DEV, strerror(errno));
        return 1;
    }
    PASS("open(%s)", DEV);

    uint64_t size = 0;
    if (ioctl(fd, BLKGETSIZE64, &size) != 0 || size == 0) {
        FAIL("BLKGETSIZE64: %s", strerror(errno));
        close(fd);
        return 1;
    }
    PASS("device size %llu bytes (%.1f MiB)",
         (unsigned long long)size, size / (1024.0 * 1024.0));

    /* Rotating I/O sizes (all LBA multiples, all <= max_io_size 1 MiB). */
    static const size_t CHUNKS[] = {
        4u * 1024, 64u * 1024, 256u * 1024,
        1024u * 1024, 128u * 1024, 512u * 1024,
    };
    constexpr size_t NCHUNK = sizeof(CHUNKS) / sizeof(CHUNKS[0]);
    constexpr size_t MAXBUF = 1024u * 1024;

    uint8_t *buf = static_cast<uint8_t *>(aligned_io(MAXBUF));
    if (!buf) { FAIL("alloc"); close(fd); return 1; }

    /* Write the whole device with rotating chunk sizes. */
    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t off = 0;
    size_t ci = 0;
    bool ok = true;
    while (off < size) {
        size_t chunk = CHUNKS[ci++ % NCHUNK];
        if (off + chunk > size) chunk = static_cast<size_t>(size - off);
        for (size_t j = 0; j < chunk; j++) buf[j] = payload_byte(off + j);
        ssize_t n = pwrite(fd, buf, chunk, static_cast<off_t>(off));
        if (n != static_cast<ssize_t>(chunk)) {
            FAIL("pwrite %zu @ %llu: ret=%zd errno=%d %s",
                 chunk, (unsigned long long)off, n, errno, strerror(errno));
            ok = false; break;
        }
        off += chunk;
    }
    if (ok && fsync(fd) != 0) { FAIL("fsync: %s", strerror(errno)); ok = false; }
    auto t1 = std::chrono::high_resolution_clock::now();
    if (ok) {
        double s = std::chrono::duration<double>(t1 - t0).count();
        PASS("wrote %llu MiB in %.1f s (%.1f MB/s)",
             (unsigned long long)(size / (1024 * 1024)), s,
             (size / (1024.0 * 1024.0)) / s);
    }

    /* Read the whole device back and verify every byte. */
    if (ok) {
        auto r0 = std::chrono::high_resolution_clock::now();
        off = 0; ci = 0;
        while (off < size) {
            size_t chunk = CHUNKS[ci++ % NCHUNK];
            if (off + chunk > size) chunk = static_cast<size_t>(size - off);
            ssize_t n = pread(fd, buf, chunk, static_cast<off_t>(off));
            if (n != static_cast<ssize_t>(chunk)) {
                FAIL("pread %zu @ %llu: ret=%zd errno=%d %s",
                     chunk, (unsigned long long)off, n, errno, strerror(errno));
                ok = false; break;
            }
            for (size_t j = 0; j < chunk; j++) {
                if (buf[j] != payload_byte(off + j)) {
                    FAIL("mismatch @ %llu: exp %02x got %02x",
                         (unsigned long long)(off + j),
                         payload_byte(off + j), buf[j]);
                    ok = false; break;
                }
            }
            if (!ok) break;
            off += chunk;
        }
        auto r1 = std::chrono::high_resolution_clock::now();
        if (ok) {
            double s = std::chrono::duration<double>(r1 - r0).count();
            PASS("verified %llu MiB read-back in %.1f s (%.1f MB/s)",
                 (unsigned long long)(size / (1024 * 1024)), s,
                 (size / (1024.0 * 1024.0)) / s);
        }
    }

    free(buf);
    close(fd);
    printf("\n=== Results: %d/%d passed (%d failed) ===\n",
           tests_passed, tests_run, tests_failed);
    return tests_failed == 0 ? 0 : 1;
}
