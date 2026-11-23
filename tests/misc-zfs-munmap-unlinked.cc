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
// Usage: misc-zfs-munmap-unlinked.so [-d DIR] [-s SIZE_MIB] [-t FAULTERS] [-r ROUNDS] [-C] [-W DIR] [-b MIB]
// -C creates osv/mu4m (recordsize=4M) at /mu4m; -W DIR runs a writer that writes -b MiB chunks with fsync in DIR
// during every munmap(), so record-sized buffers are allocated on the txg sync path meanwhile.

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/mount.h>
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
static std::string wdir;      // -W: a writer thread writes and fsyncs here while munmap() runs
static long wchunk_mib = 4;

// -W writer: rewrite a 64 MiB file in wchunk_mib MiB writes with fsync, so the txg sync and the zio pipeline
// run (and allocate record-sized buffers) while munmap() holds the VMA lock.
static void* writer(void*)
{
    std::string p = wdir + "/misc-zfs-munmap-writer.dat";
    int fd = open(p.c_str(), O_CREAT | O_RDWR, 0644);
    std::vector<unsigned long long> buf((wchunk_mib << 20) / 8);
    unsigned long long x = 0x1234567;
    long off = 0;
    while (fd >= 0 && !stop) {
        for (auto& w : buf) {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17;
            w = x;
        }
        pwrite(fd, buf.data(), buf.size() * 8, off);
        fsync(fd);
        off = (off + (wchunk_mib << 20)) % (64 << 20);
    }
    close(fd);
    return nullptr;
}

// -C: create <pool>/mu4m with recordsize=4M and mount it at /mu4m through libzfs, for -W /mu4m.
static int make_bigrec_dataset()
{
    void* h = dlopen("libzfs.so", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) { printf("SKIP: no libzfs.so\n"); return -1; }
    auto init = (void* (*)())dlsym(h, "libzfs_init");
    auto create = (int (*)(void*, const char*, int, void*))dlsym(h, "zfs_create");
    auto zopen = (void* (*)(void*, const char*, int))dlsym(h, "zfs_open");
    auto setp = (int (*)(void*, const char*, const char*))dlsym(h, "zfs_prop_set");
    void* hdl = init ? init() : nullptr;
    if (!hdl || !create || !zopen || !setp) { printf("SKIP: libzfs symbols\n"); return -1; }
    create(hdl, "osv/mu4m", 1, nullptr);
    void* zh = zopen(hdl, "osv/mu4m", 1);
    int rc = zh ? setp(zh, "recordsize", "4M") : -1;
    mkdir("/mu4m", 0755);
    umount("/mu4m");
    int mrc = mount("osv/mu4m", "/mu4m", "zfs", 0, "");
    printf("dataset osv/mu4m recordsize=4M: set rc=%d, mount rc=%d\n", rc, mrc);
    return rc == 0 && mrc == 0 ? 0 : -1;
}


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
    pthread_t wt;
    if (!wdir.empty()) {
        pthread_create(&wt, nullptr, writer, nullptr);
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
    if (!wdir.empty()) {
        pthread_join(wt, nullptr);
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
    bool mk = false;
    while ((opt = getopt(argc, argv, "d:s:t:r:W:b:C")) != -1) {
        switch (opt) {
        case 'd': dir = optarg; break;
        case 's': size_mib = atol(optarg); break;
        case 't': faulters = atoi(optarg); break;
        case 'r': rounds = atoi(optarg); break;
        case 'W': wdir = optarg; break;
        case 'b': wchunk_mib = atol(optarg); break;
        case 'C': mk = true; break;
        default:
            fprintf(stderr, "usage: %s [-d dir] [-s MiB] [-t faulters] [-r rounds]\n", argv[0]);
            return 2;
        }
    }
    if (mk && make_bigrec_dataset() != 0) {
        return 0;
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
