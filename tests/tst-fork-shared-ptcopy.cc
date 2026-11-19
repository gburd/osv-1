/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// A forking server (PostgreSQL's postmaster) keeps most of what it has mapped
// in MAP_SHARED memory, and fork copies the page tables of that memory into
// every child. This test checks what that copy must preserve, with shared
// memory both touched and untouched before the fork, next to private memory:
//
//  - a write to shared memory on either side is seen by the other, while the
//    child runs and after it exits, including pages first touched after fork;
//  - a write to private memory on either side is seen by neither the other
//    side nor later children;
//  - the parent write-protecting part of the shared range after a fork does
//    not stop the child writing it, and the parent still sees what it wrote;
//  - the parent unmapping part of the shared range after a fork leaves the
//    child's view of it intact;
//  - free memory returns to where it was once the children have exited.
//
// It also prints the fork() time with little and with much shared memory
// touched, for comparison by eye; nothing is asserted on it.

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysinfo.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const size_t PG = 4096;
static const size_t SHARED = 64 << 20;
static const size_t TOUCHED = 32 << 20;   // the parent touches the first half
static const size_t PRIV = 8 << 20;
static const size_t WP = 2 << 20;         // write-protected after fork
static const int CHILDREN = 20;
static const long LEAK_CYCLES = 300;
static const long LIMIT_BYTES_PER_CYCLE = 16 * 1024;

static int failures;

static void fail(const char *what, long a, long b)
{
    printf("FAIL: %s (%ld, %ld)\n", what, a, b);
    failures++;
}

static volatile uint32_t *word(char *base, size_t off)
{
    return reinterpret_cast<volatile uint32_t *>(base + off);
}

static long free_bytes()
{
    struct sysinfo si;
    if (sysinfo(&si) != 0) {
        return -1;
    }
    return (long)si.freeram * si.mem_unit;
}

static double now_us()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

// The child of round @r: checks what it inherited, writes its own marks, and
// exits nonzero on the first mismatch. @go and @done synchronize it with the
// parent's post-fork writes.
static void child(int r, char *sh, char *pv, int go, int done)
{
    char c;
    int bad = 0;
    // The parent writes page 4 as soon as fork() returns: skip it here.
    for (size_t off = 0; off < TOUCHED; off += PG) {
        if (off != 4 * PG && *word(sh, off) != (uint32_t)(off / PG + 1)) {
            bad = 1;
        }
    }
    for (size_t off = TOUCHED; off < SHARED; off += PG * 64) {
        if (*word(sh, off) > (uint32_t)CHILDREN) {
            bad = 2;
        }
    }
    for (size_t off = 0; off < PRIV; off += PG) {
        if (*word(pv, off) != (uint32_t)(0x1000000 + off / PG)) {
            bad = 3;
        }
    }
    if (read(go, &c, 1) != 1) {
        _exit(10);
    }
    // The parent wrote the shared mark, a private value, and write-protected
    // the tail of the touched range in its own address space.
    if (*word(sh, 4 * PG) != 0xabc00000u + r) {
        bad = 4;
    }
    if (*word(pv, 4 * PG) != (uint32_t)(0x1000000 + 4)) {
        bad = 5;
    }
    *word(sh, PG * (8 + r)) = 0xc0de0000u + r;
    *word(sh, TOUCHED + PG * 64 * r) = (uint32_t)r + 1;
    *word(sh, TOUCHED - WP + PG * r) = 0x77000000u + r;
    for (size_t off = 0; off < PRIV; off += PG) {
        *word(pv, off) = 0xdead0000u + r;
    }
    if (write(done, "x", 1) != 1) {
        _exit(11);
    }
    _exit(bad);
}

static void round_trip(int r, char *sh, char *pv)
{
    int go[2], done[2];
    if (pipe(go) || pipe(done)) {
        fail("pipe", r, errno);
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        fail("fork", r, errno);
        return;
    }
    if (pid == 0) {
        child(r, sh, pv, go[0], done[1]);
    }
    *word(sh, 4 * PG) = 0xabc00000u + r;
    *word(pv, 4 * PG) = 0x5eed0000u + r;
    if (mprotect(sh + TOUCHED - WP, WP, PROT_READ)) {
        fail("mprotect ro", r, errno);
    }
    char c;
    if (write(go[1], "g", 1) != 1 || read(done[0], &c, 1) != 1) {
        fail("pipe handshake", r, errno);
    }
    if (*word(sh, PG * (8 + r)) != 0xc0de0000u + r) {
        fail("parent sees child's shared write", r, *word(sh, PG * (8 + r)));
    }
    if (*word(sh, TOUCHED + PG * 64 * r) != (uint32_t)r + 1) {
        fail("parent sees child's first touch", r, *word(sh, TOUCHED + PG * 64 * r));
    }
    if (*word(sh, TOUCHED - WP + PG * r) != 0x77000000u + r) {
        fail("parent sees child's write to its read-only range", r, 0);
    }
    if (mprotect(sh + TOUCHED - WP, WP, PROT_READ | PROT_WRITE)) {
        fail("mprotect rw", r, errno);
    }
    int st;
    if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st)) {
        fail("child checks", r, WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    }
    for (size_t off = 0; off < PRIV; off += PG) {
        if (off != 4 * PG && *word(pv, off) != (uint32_t)(0x1000000 + off / PG)) {
            fail("child's private write reached the parent", r, off / PG);
            break;
        }
    }
    *word(pv, 4 * PG) = 0x1000000 + 4;
    close(go[0]); close(go[1]); close(done[0]); close(done[1]);
}

// The parent unmaps part of the touched shared range while a child still
// maps it, then allocates and fills memory so a freed frame would be reused.
// The child must keep seeing what the range held at the fork, as on Linux.
static void unmap_under_child(char *sh)
{
    const size_t start = TOUCHED - 2 * WP;
    int go[2];
    if (pipe(go)) {
        fail("pipe", 0, errno);
        return;
    }
    pid_t pid = fork();
    if (pid == 0) {
        char c;
        if (read(go[0], &c, 1) != 1) {
            _exit(10);
        }
        for (size_t off = start; off < start + WP; off += PG) {
            if (*word(sh, off) != (uint32_t)(off / PG + 1)) {
                _exit(1);
            }
        }
        _exit(0);
    }
    if (munmap(sh + start, WP)) {
        fail("munmap", 0, errno);
    }
    char *fill = static_cast<char *>(mmap(nullptr, 4 * WP, PROT_READ | PROT_WRITE,
                                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    if (fill != MAP_FAILED) {
        memset(fill, 0x5a, 4 * WP);
    }
    if (write(go[1], "g", 1) != 1) {
        fail("pipe write", 0, errno);
    }
    int st;
    if (waitpid(pid, &st, 0) != pid || !WIFEXITED(st) || WEXITSTATUS(st)) {
        fail("child sees a range its parent unmapped after fork", 0,
             WIFEXITED(st) ? WEXITSTATUS(st) : -1);
    }
    if (fill != MAP_FAILED) {
        munmap(fill, 4 * WP);
    }
    close(go[0]);
    close(go[1]);
}

// Mean fork() time in the parent over @n forks of a child that exits at once.
static double fork_us(int n)
{
    double total = 0;
    for (int i = 0; i < n; i++) {
        double t0 = now_us();
        pid_t pid = fork();
        if (pid == 0) {
            _exit(0);
        }
        total += now_us() - t0;
        waitpid(pid, nullptr, 0);
    }
    return total / n;
}

int main()
{
    errno = 0;
    pid_t probe = fork();
    if (probe == -1 && errno == ENOSYS) {
        printf("SKIP: fork() not enabled\n");
        printf("SUMMARY: 0 failures\n");
        return 0;
    }
    if (probe == 0) {
        _exit(0);
    }
    waitpid(probe, nullptr, 0);

    char *sh = static_cast<char *>(mmap(nullptr, SHARED, PROT_READ | PROT_WRITE,
                                        MAP_SHARED | MAP_ANONYMOUS, -1, 0));
    char *pv = static_cast<char *>(mmap(nullptr, PRIV, PROT_READ | PROT_WRITE,
                                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    if (sh == MAP_FAILED || pv == MAP_FAILED) {
        printf("FAIL: mmap (errno=%d)\nSUMMARY: 1 failures\n", errno);
        return 1;
    }
    for (size_t off = 0; off < PG * 2; off += PG) {
        *word(sh, off) = (uint32_t)(off / PG + 1);
    }
    double few = fork_us(50);
    for (size_t off = 0; off < TOUCHED; off += PG) {
        *word(sh, off) = (uint32_t)(off / PG + 1);
    }
    for (size_t off = 0; off < PRIV; off += PG) {
        *word(pv, off) = (uint32_t)(0x1000000 + off / PG);
    }
    double many = fork_us(50);
    printf("fork() %.1f us with 2 shared pages touched, %.1f us with %zu\n",
           few, many, TOUCHED / PG);

    for (int r = 0; r < CHILDREN; r++) {
        round_trip(r, sh, pv);
        // Put back the marks the round wrote into the range the next child
        // checks.
        *word(sh, 4 * PG) = 5;
        *word(sh, PG * (8 + r)) = 8 + r + 1;
        *word(sh, TOUCHED - WP + PG * r) = (uint32_t)((TOUCHED - WP) / PG + r + 1);
    }
    unmap_under_child(sh);

    for (long i = 0; i < 50; i++) {
        fork_us(1);
    }
    sleep(1);
    long before = free_bytes();
    for (long i = 0; i < LEAK_CYCLES; i++) {
        fork_us(1);
    }
    sleep(1);
    long after = free_bytes();
    long per_cycle = (before - after) / LEAK_CYCLES;
    printf("free memory %ld -> %ld KiB over %ld forks: %ld bytes per fork (limit %ld)\n",
           before / 1024, after / 1024, LEAK_CYCLES, per_cycle, LIMIT_BYTES_PER_CYCLE);
    if (per_cycle > LIMIT_BYTES_PER_CYCLE) {
        fail("memory leaks across fork", per_cycle, LIMIT_BYTES_PER_CYCLE);
    }
    if (!failures) {
        printf("PASS: shared and private memory keep their semantics across fork\n");
    }
    printf("SUMMARY: %d failures\n", failures);
    return failures ? 1 : 0;
}
