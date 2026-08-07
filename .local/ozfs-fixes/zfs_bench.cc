/*
 * OpenZFS-on-OSv raw-NVMe throughput microbench.
 *
 * Creates a zpool on the passed-through block device (default /dev/vblk1),
 * makes a dataset, then does large-buffer sequential write + read and reports
 * MB/s.  Meant to measure whether OpenZFS-on-OSv hits NVMe-class throughput
 * (GB/s on KVM) rather than being TCG-slow or artificially capped.
 *
 * Usage (kernel cmdline args after the .so name):
 *   zfs-bench.so [device] [pool] [size_mb] [recordsize]
 * Defaults: /dev/vblk1 bench 4096 1M
 */
extern "C" int osv_run_app(const char *app_path, const char *args[], int args_len);
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <vector>
#include <string>
#include <chrono>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

using clk = std::chrono::high_resolution_clock;
static double secs(clk::duration d) {
    return std::chrono::duration_cast<std::chrono::duration<double>>(d).count();
}

extern "C" void zfsdev_init();

static int run_cmd(const char *path, std::vector<std::string> args) {
    std::vector<const char*> c;
    for (auto &a : args) c.push_back(a.c_str());
    int ret = osv_run_app(path, c.data(), c.size());
    printf("  $ %s", path);
    for (auto &a : args) printf(" %s", a.c_str());
    printf("   -> ret=%d\n", ret);
    return ret;
}

static unsigned long parse_ul(const char *s) {
    unsigned long v = 0;
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return v;
}

int main(int ac, char **av) {
    const char *dev  = ac > 1 ? av[1] : "/dev/vblk1";
    const char *pool = ac > 2 ? av[2] : "bench";
    unsigned long size_mb = ac > 3 ? parse_ul(av[3]) : 4096;
    const char *recsize = ac > 4 ? av[4] : "1M";

    printf("=== zfs-bench: dev=%s pool=%s size=%luMB recordsize=%s ===\n",
           dev, pool, size_mb, recsize);

    zfsdev_init();
    mkdir("/etc", 0755);
    int fd = creat("/etc/mnttab", 0644);
    if (fd >= 0) close(fd);

    // Raw-speed pool: ashift=12, compression=off, no altroot indirection.
    if (run_cmd("/zpool.so", {"zpool", "create", "-f", "-o", "ashift=12",
                              "-O", "compression=off", "-O", "atime=off",
                              std::string(pool), std::string(dev)}) != 0) {
        printf("RESULT: FAIL zpool create\n");
        return 1;
    }
    std::string ds = std::string(pool) + "/fs";
    run_cmd("/zfs.so", {"zfs", "create", "-o", std::string("recordsize=") + recsize,
                        ds});

    run_cmd("/zpool.so", {"zpool", "status", std::string(pool)});
    run_cmd("/zpool.so", {"zpool", "get", "ashift", std::string(pool)});

    std::string path = "/" + ds + "/f0";
    unsigned long size = size_mb * 1024UL * 1024UL;
    const size_t BUF = 1024 * 1024;            // 1 MiB buffer
    char *buf = (char*)malloc(BUF);
    memset(buf, 0xAB, BUF);

    // --- sequential write ---
    int wf = open(path.c_str(), O_CREAT | O_WRONLY | O_LARGEFILE, 0644);
    assert(wf >= 0);
    auto t0 = clk::now();
    unsigned long left = size;
    while (left) {
        size_t n = left < BUF ? left : BUF;
        ssize_t w = write(wf, buf, n);
        assert(w == (ssize_t)n);
        left -= n;
    }
    fsync(wf);
    close(wf);
    double wt = secs(clk::now() - t0);
    printf("RESULT: seq_write %.1f MB in %.2fs = %.1f MB/s\n",
           (double)size_mb, wt, size_mb / wt);

    // --- cold sequential read ---
    // Skip export/import (OSv export path has a separate mutex bug); rely on
    // the working set being larger than ARC so most reads miss cache.  For a
    // true cold read the caller should pass size_mb >> ARC size.
    int rf = open(path.c_str(), O_RDONLY | O_LARGEFILE);
    assert(rf >= 0);
    t0 = clk::now();
    left = size;
    unsigned long total = 0;
    while (left) {
        size_t n = left < BUF ? left : BUF;
        ssize_t r = read(rf, buf, n);
        if (r <= 0) break;
        total += r;
        left -= r;
    }
    double rt = secs(clk::now() - t0);
    printf("RESULT: seq_read_cold %.1f MB in %.2fs = %.1f MB/s (read %lu MB)\n",
           (double)size_mb, rt, size_mb / rt, total / (1024*1024));

    // --- warm read (same file, now in ARC) ---
    lseek(rf, 0, SEEK_SET);
    t0 = clk::now();
    left = size;
    while (left) {
        size_t n = left < BUF ? left : BUF;
        ssize_t r = read(rf, buf, n);
        if (r <= 0) break;
        left -= r;
    }
    double rwt = secs(clk::now() - t0);
    printf("RESULT: seq_read_warm %.1f MB in %.2fs = %.1f MB/s\n",
           (double)size_mb, rwt, size_mb / rwt);
    close(rf);

    free(buf);
    printf("=== zfs-bench done ===\n");
    return 0;
}
