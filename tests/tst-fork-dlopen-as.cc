/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * A shared object must be usable from an address space that did not load it.
 *
 * elf::program's object cache (_files) and module list are process-global, but
 * an object's PT_LOAD segments are mapped into whichever address space was
 * current when it was first loaded (file::load_segment -> mmu::map_file ->
 * cur_vma_list()).  Under fork() each child has a private address space, so the
 * two disagree: a child that dlopen()s a library another address space already
 * loaded used to receive the cached object with no mapping of its own, and the
 * first dereference of its _dynamic_table (from dlsym -> lookup_symbol_deep ->
 * dynamic_tag) took a fatal "page fault outside application" at a page-aligned
 * address that was identical on every occurrence, since the object's base is
 * fixed at its first load.
 *
 * This is the shape of a PostgreSQL backend loading an extension: the first
 * forked backend to dlopen() it succeeds, and every later backend faults.
 *
 * Each round forks a child that dlopen()s the library, dlsym()s a function and
 * calls it.  Round 0 is the first loader; every later round exercises the cache
 * hit from a different address space.  A wrong return value catches the weaker
 * failure where the mapping exists but the relocations or the constructor were
 * not established for this address space.
 */

#include <unistd.h>
#include <sys/wait.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>

#define ROUNDS 12
#define EXPECTED 42

static int failures;

static void report(bool ok, const char *msg)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", msg);
    if (!ok) {
        failures++;
    }
}

// Runs in the forked child: load the library, resolve a symbol, call it.
// Exits 0 only if the call returns the expected value.
static void child_body()
{
    void *h = dlopen("/tests/libdlopenas.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("child: dlopen failed: %s\n", dlerror());
        _exit(2);
    }
    auto fn = reinterpret_cast<int (*)()>(dlsym(h, "dlopenas_value"));
    if (!fn) {
        printf("child: dlsym failed: %s\n", dlerror());
        _exit(3);
    }
    // Before the fix this call site was never reached: the fault happened
    // inside dlsym, walking the cached object's dynamic table.
    int v = fn();
    if (v != EXPECTED) {
        printf("child: got %d, expected %d\n", v, EXPECTED);
        _exit(4);
    }
    _exit(0);
}

int main()
{
    printf("tst-fork-dlopen-as: dlopen from an address space that did not load\n");

    for (int i = 0; i < ROUNDS; i++) {
        pid_t p = fork();
        if (p == 0) {
            child_body();
            _exit(5);
        }
        if (p < 0) {
            report(false, "fork failed");
            break;
        }
        int st = 0;
        if (waitpid(p, &st, 0) != p) {
            report(false, "waitpid failed");
            break;
        }
        char msg[96];
        snprintf(msg, sizeof(msg),
                 "round %d: child dlopen + dlsym + call (status %d)", i, st);
        report(WIFEXITED(st) && WEXITSTATUS(st) == 0, msg);
    }

    // Second variant: the FIRST loader is a forked child, and the second
    // consumer is the PARENT address space.  The bug is not specific to a
    // forked child being the victim: any address space that did not load the
    // object hits it, including the original one.
    void *h = dlopen("/tests/libdlopenas.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        report(false, "parent dlopen failed");
    } else {
        auto fn = reinterpret_cast<int (*)()>(dlsym(h, "dlopenas_value"));
        if (!fn) {
            report(false, "parent dlsym failed");
        } else {
            report(fn() == EXPECTED, "parent (the address space that did not "
                                     "load it) dlopen + dlsym + call");
        }
    }

    printf("tst-fork-dlopen-as: %d failures\n", failures);
    return failures == 0 ? 0 : 1;
}
