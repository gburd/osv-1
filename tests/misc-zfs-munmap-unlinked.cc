/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Measure what dropping the last reference to a removed file inside munmap()
// costs the rest of the system.
//
// munmap() holds the VMA list lock for writing while it destroys the file
// VMA, and the VMA holds a reference to the file.  If the file was closed and
// unlinked first, that reference is the last one, so freeing the file's
// blocks runs under the lock, and every page fault in the system waits.
//
// The program writes a file of SIZE MiB, maps it, touches every page, closes
// and (in the "unlinked" arm) unlinks it, then munmap()s it while FAULTERS
// threads take page faults on fresh anonymous memory and record the longest
// single fault.  The "kept" arm does the same without the unlink, as the
// control.  It prints the munmap() time and the worst fault for each arm.
//
// Usage: misc-zfs-munmap-unlinked.so [-d DIR] [-s SIZE_MIB] [-t FAULTERS] [-r ROUNDS]

#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <string>
#include <vector>

static std::string dir = "/";
static long size_mib = 1024;
static int faulters = 3;
static int rounds = 3;

static std::atomic<bool> stop;
static std::atomic<bool> measuring;

static double now_ms()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

// Each faulter touches fresh pages of a private anonymous region, one fault
// per page, and remaps the region when it runs out.  It keeps the longest
// single fault seen while `measuring` is set.
static void* faulter(void* arg)
{
    double* worst = static_cast<double*>(arg);
    const size_t len = 64 << 20;
    while (!stop) {
        char* p = static_cast<char*>(mmap(nullptr, len, PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
        if (p == MAP_FAILED) {
            perror("mmap anon");
            exit(1);
        }
        for (size_t off = 0; off < len && !stop; off += 4096) {
            double t0 = now_ms();
            p[off] = 1;
            double dt = now_ms() - t0;
            if (measuring && dt > *worst) {
                *worst = dt;
            }
        }
        munmap(p, len);
    }
    return nullptr;
}

static void write_file(const std::string& path)
{
    int fd = open(path.c_str(), O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        perror(path.c_str());
        exit(1);
    }
    static unsigned long long buf[1 << 17];
    unsigned long long x = 0x9e3779b97f4a7c15ULL;
    for (long i = 0; i < size_mib; i++) {
        for (auto& w : buf) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            w = x;
        }
        if (write(fd, buf, sizeof(buf)) != (ssize_t)sizeof(buf)) {
            perror("write");
            exit(1);
        }
    }
    fsync(fd);
    close(fd);
}

// One arm: map the file, touch it, drop the fd (and the name when unlink is
// set), and time munmap() while the faulters run.
static void run_arm(const std::string& path, bool unlink_it)
{
    write_file(path);
    sync();
    printf("  written\n"); fflush(stdout);
    int fd = open(path.c_str(), O_RDONLY);
    size_t len = size_mib << 20;
    char* m = static_cast<char*>(mmap(nullptr, len, PROT_READ, MAP_SHARED, fd, 0));
    if (m == MAP_FAILED) {
        perror("mmap file");
        exit(1);
    }
    printf("  mapped\n"); fflush(stdout);
    volatile char sink = 0;
    for (size_t off = 0; off < len; off += 4096) {
        sink += m[off];
    }
    (void)sink;
    printf("  touched\n"); fflush(stdout);
    close(fd);
    if (unlink_it) {
        unlink(path.c_str());
    }

    std::vector<double> worst(faulters, 0.0);
    std::vector<pthread_t> th(faulters);
    stop = false;
    for (int i = 0; i < faulters; i++) {
        pthread_create(&th[i], nullptr, faulter, &worst[i]);
    }
    printf("  faulters started\n"); fflush(stdout);
    usleep(200 * 1000);
    double base_worst = 0;
    measuring = true;
    usleep(500 * 1000);
    base_worst = *std::max_element(worst.begin(), worst.end());
    std::fill(worst.begin(), worst.end(), 0.0);
    double t0 = now_ms();
    munmap(m, len);
    double unmap_ms = now_ms() - t0;
    printf("  unmapped\n"); fflush(stdout);
    usleep(200 * 1000);
    measuring = false;
    stop = true;
    for (auto& t : th) {
        pthread_join(t, nullptr);
    }
    double w = *std::max_element(worst.begin(), worst.end());
    printf("%s: munmap %.1f ms, worst fault during it %.1f ms (%.2f ms before it)\n",
           unlink_it ? "unlinked" : "kept", unmap_ms, w, base_worst);
    fflush(stdout);
    if (!unlink_it) {
        unlink(path.c_str());
    }
    sync();
}

int main(int argc, char** argv)
{
    int opt;
    while ((opt = getopt(argc, argv, "d:s:t:r:")) != -1) {
        switch (opt) {
        case 'd': dir = optarg; break;
        case 's': size_mib = atol(optarg); break;
        case 't': faulters = atoi(optarg); break;
        case 'r': rounds = atoi(optarg); break;
        default:
            fprintf(stderr, "usage: %s [-d dir] [-s MiB] [-t faulters] [-r rounds]\n", argv[0]);
            return 2;
        }
    }
    std::string path = dir + (dir.back() == '/' ? "" : "/") + "misc-zfs-munmap-unlinked.dat";
    printf("dir %s, %ld MiB, %d faulters, %d rounds\n", dir.c_str(), size_mib, faulters, rounds);
    fflush(stdout);
    for (int r = 0; r < rounds; r++) {
        run_arm(path, false);
        run_arm(path, true);
    }
    printf("DONE\n");
    fflush(stdout);
    return 0;
}
