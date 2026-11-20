/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// sync_file_range(2): the argument checks Linux makes, and that the call
// leaves the file's data (written with write() or through a MAP_SHARED
// mapping) readable and still fsync()able.  Usage: tst-sync-file-range [dir]
// (default /tmp); the image's root file system is the one under test when
// dir is on it.

#include <sys/mman.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int tests = 0, fails = 0;

static void report(bool ok, const char *msg)
{
    ++tests;
    fails += !ok;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", msg);
}

// Expect sync_file_range() to fail with `err`.
static void expect_err(int fd, off_t off, off_t len, unsigned flags, int err, const char *msg)
{
    errno = 0;
    int r = sync_file_range(fd, off, len, flags);
    report(r == -1 && errno == err, msg);
}

// Each 4 KiB page of the file holds the byte (base + page index).
static bool check_pattern(const char *path, int npages, unsigned char base)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return false;
    }
    unsigned char buf[4096];
    bool ok = true;
    for (int i = 0; i < npages && ok; i++) {
        ok = pread(fd, buf, sizeof(buf), (off_t)i * 4096) == (ssize_t)sizeof(buf) &&
             buf[0] == (unsigned char)(base + i) && buf[4095] == (unsigned char)(base + i);
    }
    close(fd);
    return ok;
}

static void test_arguments(const char *dir)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/sfr-args", dir);
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0600);
    report(fd >= 0, "open");
    report(write(fd, "data", 4) == 4, "write");

    const unsigned all = SYNC_FILE_RANGE_WAIT_BEFORE | SYNC_FILE_RANGE_WRITE |
                         SYNC_FILE_RANGE_WAIT_AFTER;
    report(sync_file_range(fd, 0, 0, SYNC_FILE_RANGE_WRITE) == 0, "WRITE, whole file");
    report(sync_file_range(fd, 0, 4, all) == 0, "all flags, a range");
    report(sync_file_range(fd, 0, 0, 0) == 0, "no flags");
    expect_err(fd, 0, 0, 0x8, EINVAL, "unknown flag bit is EINVAL");
    expect_err(fd, -1, 0, SYNC_FILE_RANGE_WRITE, EINVAL, "negative offset is EINVAL");
    expect_err(fd, 0, -1, SYNC_FILE_RANGE_WRITE, EINVAL, "negative length is EINVAL");
    expect_err(fd, INT64_MAX, 1, SYNC_FILE_RANGE_WRITE, EINVAL, "offset + length overflow is EINVAL");
    close(fd);
    unlink(path);

    expect_err(fd, 0, 0, SYNC_FILE_RANGE_WRITE, EBADF, "closed fd is EBADF");
    int p[2];
    report(pipe(p) == 0, "pipe");
    expect_err(p[0], 0, 0, SYNC_FILE_RANGE_WRITE, ESPIPE, "pipe is ESPIPE");
    close(p[0]);
    close(p[1]);
}

// Data written with write() reads back after sync_file_range(), and a later
// fsync() still succeeds.
static void test_write_data(const char *dir)
{
    char path[512];
    const int npages = 8;
    snprintf(path, sizeof(path), "%s/sfr-write", dir);
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0600);
    unsigned char page[4096];
    bool ok = fd >= 0;
    for (int i = 0; i < npages && ok; i++) {
        memset(page, 0x20 + i, sizeof(page));
        ok = write(fd, page, sizeof(page)) == (ssize_t)sizeof(page);
    }
    report(ok, "write pattern");
    report(sync_file_range(fd, 0, 0, SYNC_FILE_RANGE_WRITE | SYNC_FILE_RANGE_WAIT_AFTER) == 0,
           "sync_file_range after write()");
    report(check_pattern(path, npages, 0x20), "write() data reads back through a new fd");
    report(fsync(fd) == 0, "fsync after sync_file_range");
    close(fd);
    unlink(path);
}

// Pages dirtied through a MAP_SHARED mapping reach the file system when
// sync_file_range() covers them: a read() through another fd sees them while
// the mapping is still in place.
static void test_mmap_data(const char *dir)
{
    char path[512];
    const int npages = 8;
    snprintf(path, sizeof(path), "%s/sfr-mmap", dir);
    int fd = open(path, O_CREAT | O_RDWR | O_TRUNC, 0600);
    report(fd >= 0 && ftruncate(fd, npages * 4096) == 0, "create mmap file");
    auto *p = static_cast<unsigned char *>(mmap(nullptr, npages * 4096, PROT_READ | PROT_WRITE,
                                                MAP_SHARED, fd, 0));
    report(p != MAP_FAILED, "mmap MAP_SHARED");
    if (p == MAP_FAILED) {
        close(fd);
        return;
    }
    for (int i = 0; i < npages; i++) {
        memset(p + i * 4096, 0x40 + i, 4096);
    }
    report(sync_file_range(fd, 0, 0, SYNC_FILE_RANGE_WRITE) == 0, "sync_file_range over mmap");
    report(check_pattern(path, npages, 0x40), "mmap data reads back through a new fd");
    report(fsync(fd) == 0, "fsync after sync_file_range");
    munmap(p, npages * 4096);
    close(fd);
    report(check_pattern(path, npages, 0x40), "mmap data reads back after munmap and close");
    unlink(path);
}

int main(int argc, char **argv)
{
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    printf("tst-sync-file-range on %s\n", dir);
    test_arguments(dir);
    test_write_data(dir);
    test_mmap_data(dir);
    printf("SUMMARY: %d tests, %d failures\n", tests, fails);
    return fails ? 1 : 0;
}
