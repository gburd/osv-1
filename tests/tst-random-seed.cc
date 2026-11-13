/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// A blocking read of /dev/random must return once the kernel has run for a
// while, even on a machine with no hardware RNG and no virtio-rng device:
// interrupts feed the pool. Run it without -device virtio-rng-pci (and, on
// aarch64, on a CPU without FEAT_RNG). The read happens in a thread so a
// pool that never seeds is reported as a failure instead of hanging.

#include <fcntl.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <thread>

int main()
{
    std::atomic<ssize_t> got{-2};
    std::thread reader([&] {
        unsigned char buf[16];
        int fd = open("/dev/random", O_RDONLY);
        if (fd < 0) {
            got = -1;
            return;
        }
        got = read(fd, buf, sizeof(buf));
        close(fd);
    });
    for (int i = 0; i < 300 && got == -2; i++) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    ssize_t n = got;
    if (n == 16) {
        printf("PASS: /dev/random returned 16 bytes\n");
        reader.join();
        return 0;
    }
    printf("FAIL: /dev/random %s after 30 s\n", n == -2 ? "still blocked" : "read failed");
    // The reader may never return; leave without joining it.
    fflush(stdout);
    _exit(1);
}
