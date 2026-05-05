/*
 * Copyright (C) 2026 OSv Authors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/*
 * ZFS recordsize benchmark: compare sequential I/O throughput with 8kB vs 128kB recordsize.
 *
 * ZFS 'recordsize' controls the minimum I/O block size per dataset:
 *   - 8K:   more suited to small random I/O (databases); higher metadata overhead
 *   - 128K: ZFS default (SPA_OLD_MAXBLOCKSIZE); optimal for sequential large-file I/O
 *
 * This test creates two datasets on the ZFS root pool with different recordsizes,
 * then measures sequential write and read throughput for each.
 *
 * Run: ./scripts/run.py --image <zfs-image> -e "tests/tst-zfs-recordsize.so"
 * Requires: ZFS root filesystem (build with fs=zfs)
 */

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <vector>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

static const size_t FILE_SIZE = 128UL * 1024 * 1024;  // 128 MB per test run

struct bench_result {
    double write_mbs;
    double read_mbs;
};

static bench_result run_one(const char *filepath, size_t io_size)
{
    using clk = std::chrono::high_resolution_clock;
    std::vector<char> buf(io_size, 0xAB);
    bench_result r = {};

    // Sequential write
    {
        int fd = open(filepath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) {
            perror("open for write");
            return r;
        }
        auto t0 = clk::now();
        for (size_t done = 0; done < FILE_SIZE; ) {
            ssize_t n = write(fd, buf.data(), buf.size());
            if (n <= 0) { perror("write"); break; }
            done += (size_t)n;
        }
        fsync(fd);
        close(fd);
        double elapsed = std::chrono::duration<double>(clk::now() - t0).count();
        r.write_mbs = (double)FILE_SIZE / (1024.0 * 1024.0) / elapsed;
    }

    // Sequential read
    {
        int fd = open(filepath, O_RDONLY);
        if (fd < 0) {
            perror("open for read");
            return r;
        }
        auto t0 = clk::now();
        for (size_t done = 0; done < FILE_SIZE; ) {
            ssize_t n = read(fd, buf.data(), buf.size());
            if (n <= 0) break;
            done += (size_t)n;
        }
        close(fd);
        double elapsed = std::chrono::duration<double>(clk::now() - t0).count();
        r.read_mbs = (double)FILE_SIZE / (1024.0 * 1024.0) / elapsed;
    }

    unlink(filepath);
    return r;
}

static const char *detect_pool(void)
{
    if (system("zfs list rpool >/dev/null 2>&1") == 0) return "rpool";
    if (system("zfs list osv   >/dev/null 2>&1") == 0) return "osv";
    return nullptr;
}

int main(void)
{
    printf("=== ZFS recordsize benchmark: 8kB vs 128kB ===\n");
    printf("Test file size: %zu MB  (I/O buffer = recordsize)\n\n",
           FILE_SIZE / (1024 * 1024));

    const char *pool = detect_pool();
    if (!pool) {
        fprintf(stderr, "SKIP: no ZFS pool found (rpool or osv)\n");
        return 1;
    }
    printf("Using pool: %s\n\n", pool);

    // Create benchmark datasets with explicit recordsizes
    {
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "zfs create -p -o recordsize=8K   -o mountpoint=/zfs-bench-8k   %s/bench8k   2>/dev/null; "
            "zfs create -p -o recordsize=128K  -o mountpoint=/zfs-bench-128k  %s/bench128k  2>/dev/null",
            pool, pool);
        system(cmd);
    }

    struct {
        const char *label;
        const char *path;
        size_t io_size;
    } cases[] = {
        { "8kB  recordsize", "/zfs-bench-8k/seq.dat",    8 * 1024 },
        { "128kB recordsize", "/zfs-bench-128k/seq.dat", 128 * 1024 },
    };

    printf("  %-22s  %10s  %10s\n", "Configuration", "Write MB/s", "Read MB/s");
    printf("  %-22s  %10s  %10s\n", "-------------", "----------", "---------");

    for (auto &c : cases) {
        bench_result r = run_one(c.path, c.io_size);
        printf("  %-22s  %10.1f  %10.1f\n", c.label, r.write_mbs, r.read_mbs);
    }

    printf("\n");
    printf("Expected: 128kB recordsize shows higher sequential throughput.\n");
    printf("Reason: fewer ZFS I/O operations for the same data volume,\n");
    printf("        less metadata overhead, better block device utilization.\n");

    // Cleanup
    {
        char cmd[256];
        snprintf(cmd, sizeof(cmd),
            "zfs destroy %s/bench8k   2>/dev/null; "
            "zfs destroy %s/bench128k 2>/dev/null",
            pool, pool);
        system(cmd);
    }

    return 0;
}
