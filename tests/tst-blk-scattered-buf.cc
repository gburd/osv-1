/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Raw block-device I/O from a buffer that is contiguous only in virtual
// memory.  The buffer comes from mmap(), so its pages are allocated one at a
// time and are generally not physically adjacent.  A driver that maps such a
// buffer for DMA by adding offsets to the physical address of its first byte
// transfers the wrong pages: the data written is not the data read back, and
// unrelated memory is overwritten.
//
// Usage: tst-blk-scattered-buf.so <device> (default /dev/vblk1).  The test
// overwrites the first 16 MiB of the device: give it a scratch disk.

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/vblk1";
    int fd = open(dev, O_RDWR);
    if (fd < 0) {
        printf("SKIP: cannot open %s\n", dev);
        return 0;
    }
    // 4 KiB .. 1 MiB transfers, page-aligned and misaligned starts, so the
    // one-page, two-page and PRP-list paths are all taken.
    const size_t sizes[] = {4096, 8192, 12288, 65536, 1 << 20};
    const size_t offsets[] = {0, 512};
    const size_t region = 2 << 20;
    int failures = 0, cases = 0;
    for (int round = 0; round < 8; round++) {
        // Touch a throwaway mapping between rounds so the next buffer's pages
        // come from a different part of the free list.
        void *spacer = mmap(nullptr, (round + 1) * 4096 * 7, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        memset(spacer, 1, (round + 1) * 4096 * 7);
        auto *w = static_cast<uint8_t*>(mmap(nullptr, region, PROT_READ | PROT_WRITE,
                                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
        auto *r = static_cast<uint8_t*>(mmap(nullptr, region, PROT_READ | PROT_WRITE,
                                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
        if (w == MAP_FAILED || r == MAP_FAILED) {
            printf("FAIL: mmap\n");
            return 1;
        }
        // Fault the pages in back to front, so physical order differs from
        // virtual order.
        for (size_t p = region; p > 0; p -= 4096) {
            w[p - 4096] = 0;
            r[p - 4096] = 0;
        }
        for (size_t s : sizes) {
            for (size_t o : offsets) {
                cases++;
                for (size_t i = 0; i < s; i++) {
                    w[o + i] = static_cast<uint8_t>((i * 131 + s + o + round) ^ (i >> 12));
                }
                memset(r + o, 0xa5, s);
                off_t at = static_cast<off_t>(round) * region;
                if (pwrite(fd, w + o, s, at) != (ssize_t)s || fsync(fd) != 0 ||
                    pread(fd, r + o, s, at) != (ssize_t)s) {
                    printf("FAIL: I/O error size=%zu misalign=%zu round=%d\n", s, o, round);
                    failures++;
                    continue;
                }
                if (memcmp(w + o, r + o, s) != 0) {
                    size_t i = 0;
                    while (w[o + i] == r[o + i]) {
                        i++;
                    }
                    printf("FAIL: data mismatch size=%zu misalign=%zu round=%d at byte %zu\n",
                           s, o, round, i);
                    failures++;
                }
            }
        }
        munmap(w, region);
        munmap(r, region);
        munmap(spacer, (round + 1) * 4096 * 7);
    }
    close(fd);
    printf("SUMMARY: %d tests, %d failures\n", cases, failures);
    return failures ? 1 : 0;
}
