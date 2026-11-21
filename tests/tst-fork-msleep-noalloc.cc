/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Regression test: a BSD msleep() must not allocate memory while a fork
 * child is alive.
 *
 * Under CONF_fork, msleep()'s waiter cannot live on the sleeper's stack: a
 * wakeup from another address space follows the sleep queue into it, and a
 * forked process's stack is private to its own address space.  It used to be
 * allocated on the kernel heap for every sleep.  Every ZFS zio taskqueue
 * worker re-sleeps through msleep() after almost every task, so that was an
 * allocation per dispatch.  It now comes from a per-thread TLS slot, which is
 * on the identity heap.
 *
 * With a fork child alive, one thread sleeps on a channel and another wakes
 * it, many times; allocations made by the sleeping thread inside msleep() are
 * counted.  Any allocation fails the test.  A second thread also sleeps with
 * a timeout, to cover the timed-out path.
 */

#include <unistd.h>
#include <sys/wait.h>
#include <pthread.h>
#include <atomic>
#include <cstdio>
#include <string>
#include <vector>
#include <osv/trace.hh>
#include <osv/sched.hh>
#include <osv/elf.hh>

#include <bsd/porting/netport.h>
#include <bsd/porting/sync_stub.h>
#include <bsd/porting/synch.h>

// The probe's hit() runs inside the allocator; keep this object resident.
OSV_ELF_MLOCK_OBJECT();

struct thread_probe : tracepoint_base::probe {
    std::atomic<sched::thread *> target{nullptr};
    std::atomic<long> hits{0};
    void hit() override {
        if (sched::thread::current() == target.load(std::memory_order_relaxed)) {
            hits.fetch_add(1, std::memory_order_relaxed);
        }
    }
};

static struct mtx g_m;
static char g_chan;
static std::atomic<int> g_asleep{0};
static const int rounds = 500;

static void *waker(void *)
{
    for (int i = 0; i < rounds; i++) {
        while (g_asleep.load() != i + 1) {
            sched::thread::yield();
        }
        mtx_lock(&g_m);   // the sleeper is inside msleep() once it released g_m
        mtx_unlock(&g_m);
        wakeup_one(&g_chan);
    }
    return nullptr;
}

int main()
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("=== tst-fork-msleep-noalloc ===\n");
    mtx_init(&g_m, "noalloc", nullptr, MTX_DEF);

    thread_probe allocs;
    std::vector<tracepoint_base *> attached;
    for (auto &tp : tracepoint_base::tp_list) {
        std::string n(tp.name);
        if (n == "memory_malloc" || n == "memory_malloc_mempool" ||
            n == "memory_malloc_page" || n == "memory_malloc_large") {
            attached.push_back(&tp);
        }
    }
    if (attached.size() < 3) {
        printf("FAIL: tracepoints not found (%zu)\n", attached.size());
        return 1;
    }
    for (auto *tp : attached) {
        tp->add_probe(&allocs);
    }

    int pfd[2];
    if (pipe(pfd)) {
        perror("pipe");
        return 1;
    }
    pid_t child = fork();
    if (child < 0) {
        printf("SKIP: fork() unavailable\n");
        return 0;
    }
    if (child == 0) {
        char c;
        read(pfd[0], &c, 1);   // stay alive until the parent is done
        _exit(0);
    }

    pthread_t w;
    pthread_create(&w, nullptr, waker, nullptr);
    auto self = sched::thread::current();
    int woken = 0, timedout = 0;
    for (int i = 0; i < rounds; i++) {
        mtx_lock(&g_m);
        g_asleep.store(i + 1);
        allocs.target.store(self);
        int r = msleep(&g_chan, &g_m, 0, "noalloc", 5000);
        allocs.target.store(nullptr);
        mtx_unlock(&g_m);
        woken += r == 0;
    }
    pthread_join(w, nullptr);
    // The timed-out path: nobody wakes these.
    for (int i = 0; i < 50; i++) {
        mtx_lock(&g_m);
        allocs.target.store(self);
        int r = msleep(&g_chan, &g_m, 0, "noalloc", 1);
        allocs.target.store(nullptr);
        mtx_unlock(&g_m);
        timedout += r == EWOULDBLOCK;
    }

    write(pfd[1], "x", 1);
    int st;
    waitpid(child, &st, 0);
    for (auto *tp : attached) {
        tp->del_probe(&allocs);
    }

    long a = allocs.hits.load();
    printf("%d woken and %d timed-out msleep() calls with a live fork child: %ld allocations\n",
           woken, timedout, a);
    if (woken != rounds || timedout != 50) {
        printf("FAIL: expected %d woken and 50 timed out\n", rounds);
        return 1;
    }
    if (a) {
        printf("SUMMARY: FAIL\n");
        return 1;
    }
    printf("SUMMARY: 0 failures\n");
    return 0;
}
