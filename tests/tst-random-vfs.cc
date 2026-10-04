/* Copyright (C) 2026 Greg Burd. BSD license; see LICENSE. */
// Opt-in destructive test: one CPU, no live RNG. Harvest stays disabled.
// Uses master's existing flush/reseed API, not reseed-feature reset hooks.
// Opt-in assertions must execute in release kernels too.
#undef NDEBUG
#include <cassert>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
#include <sys/uio.h>
#include <osv/sched.hh>
#include <osv/device.h>
#include <osv/vnode.h>
#include <osv/uio.h>
#include <sys/param.h>
#include <sys/mutex.h>
#include <dev/random/randomdev.h>
#include <dev/random/randomdev_soft.h>
#include <dev/random/random_adaptors.h>
#include <dev/random/live_entropy_sources.h>

// Let the same test compile against master for the blocking negative control.
#ifdef IO_NONBLOCK
static_assert((IO_NONBLOCK & (IO_DIRECT | IO_APPEND | IO_SYNC)) == 0,
    "nonblocking IO must not select direct, append or sync IO");
#else
#define IO_NONBLOCK 0x0008
#endif

static int seen_flags;
static int record_io(device*, uio* io, int flags)
{
    seen_flags = flags;
    io->uio_resid = 0;
    return 0;
}
static devops record_ops{no_open, no_close, record_io, record_io, no_ioctl, no_devctl};
static driver record_driver{"rng-flags", &record_ops};

int main()
{
    assert(sched::cpus.size() == 1);
    assert(live_entropy_sources_empty());
    randomdev_deinit_harvester();
    random_adaptor->reseed();
    mtx_lock(&random_reseed_mtx);
    random_adaptor->seeded = 1;
    mtx_unlock(&random_reseed_mtx);
    random_adaptor->reseed();
    mtx_lock(&random_reseed_mtx);
    random_adaptor->seeded = 0;
    mtx_unlock(&random_reseed_mtx);
    assert(random_adaptor->block(O_NONBLOCK) == EWOULDBLOCK);
    puts("CONTROL: unseeded, harvest disabled, no hardware source");

    char buf[32] = {};
    int fd = open("/dev/null", O_RDWR | O_NONBLOCK | O_SYNC | O_APPEND);
    assert(fd >= 0);
    assert(read(fd, buf, sizeof(buf)) == 0);
    assert(write(fd, buf, sizeof(buf)) == sizeof(buf));
    assert(pread(fd, buf, sizeof(buf), 0) == 0);
    assert(pwrite(fd, buf, sizeof(buf), 0) == sizeof(buf));
    assert(close(fd) == 0);
    fd = open("/tmp/rng-flags", O_CREAT | O_TRUNC | O_RDWR | O_NONBLOCK | O_SYNC, 0600);
    assert(fd >= 0);
    assert(write(fd, "a", 1) == 1);
    assert(fcntl(fd, F_SETFL, O_RDWR | O_APPEND | O_NONBLOCK) == 0);
    assert(lseek(fd, 0, SEEK_SET) == 0);
    assert(write(fd, "b", 1) == 1);
    assert(pread(fd, buf, 2, 0) == 2 && memcmp(buf, "ab", 2) == 0);
    assert(close(fd) == 0);
    assert(unlink("/tmp/rng-flags") == 0);
    puts("CONTROL: null and regular-file append/read/write unchanged");

    // Baseline blocks forever with controlled zero credit. Fail an assertion
    // inside the guest, rather than treating external QEMU timeout as evidence.
    std::atomic<bool> done{false};
    std::thread watchdog([&] {
        std::this_thread::sleep_for(std::chrono::seconds(3));
        assert(done.load() && "VFS O_NONBLOCK read blocked");
    });
    for (const char* path : {"/dev/random", "/dev/urandom"}) {
        fd = open(path, O_RDONLY | O_NONBLOCK);
        assert(fd >= 0);
        for (size_t size : {1U, 16U, 32U}) {
            errno = 0;
            assert(read(fd, buf, size) == -1 && errno == EAGAIN);
            errno = 0;
            assert(pread(fd, buf, size, 0) == -1 && errno == EAGAIN);
            iovec iov{buf, size};
            errno = 0;
            assert(readv(fd, &iov, 1) == -1 && errno == EAGAIN);
        }
        assert(close(fd) == 0);
    }
    done.store(true);
    watchdog.join();
    puts("PASS: actual VFS random/urandom read/pread/readv return EAGAIN");
    // Real devfs/VFS dispatch into a recording device checks both IO namespaces
    // and positioned block-device fast paths without touching a real disk.
    for (int type : {D_CHR, D_BLK}) {
        const char* name = type == D_CHR ? "rng-flags-c" : "rng-flags-b";
        assert(device_create(&record_driver, name, type));
        char path[64];
        snprintf(path, sizeof(path), "/dev/%s", name);
        for (int mask = 0; mask < 32; ++mask) {
            int flags = (mask & 1 ? O_NONBLOCK : 0) | (mask & 2 ? O_APPEND : 0)
                | (mask & 4 ? O_SYNC : 0) | (mask & 8 ? O_DSYNC : 0)
                | (mask & 16 ? O_DIRECT : 0);
            fd = open(path, O_RDWR | flags);
            assert(fd >= 0);
            const int read_flags = flags & O_NONBLOCK ? IO_NONBLOCK : 0;
            const int write_flags = read_flags | (flags & O_APPEND ? IO_APPEND : 0)
                | (flags & (O_SYNC | O_DSYNC) ? IO_SYNC : 0);
            assert(read(fd, buf, 1) == 1 && seen_flags == read_flags);
            assert(pread(fd, buf, 1, 0) == 1 && seen_flags == read_flags);
            assert(write(fd, buf, 1) == 1 && seen_flags == write_flags);
            assert(pwrite(fd, buf, 1, 0) == 1);
            assert(seen_flags == (type == D_BLK ? write_flags & ~IO_APPEND : write_flags));
            assert(close(fd) == 0);
        }
    }
    puts("PASS: character/block device IO flag translation, positioned and sequential");
}
