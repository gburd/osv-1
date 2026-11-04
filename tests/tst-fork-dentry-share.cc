/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Dentries are shared by every address space: one set of hash chains, walked
 * by every process.  Under CONF_fork they (and their d_path) must therefore be
 * allocated on the identity kernel heap, not in the allocating process's COW
 * fork-arena window.  If one lands in a window, another address space sees an
 * unmapped page (the owner exited) or its own stale COW copy (the owner wrote
 * after fork), and a later lookup or release faults or underflows d_refcnt.
 *
 * Phase A: a child creates and renames files (dentry_alloc, dentry_move) and
 *          exits; the parent then looks them up and removes them.
 * Phase B: the parent creates files after fork; the child looks them up,
 *          opens and closes them, and exits; the parent removes them.
 * Phase C: phase A repeated by several concurrent children.
 *
 * A crash (page fault in dentry_lookup, or drele's d_refcnt assert) is the
 * failure; every path must also resolve.
 */
#include <sys/stat.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>

static int failures;

static void check(bool ok, const char *what, const char *path)
{
    if (!ok) {
        printf("FAIL: %s %s errno=%d (%s)\n", what, path, errno, strerror(errno));
        failures++;
    }
}

static const int nfiles = 64;

static void path_of(char *buf, size_t n, const char *dir, const char *pfx, int i)
{
    snprintf(buf, n, "%s/%s%d", dir, pfx, i);
}

// Create nfiles files and rename half of them, from the calling process.
static int create_and_rename(const char *dir)
{
    char p[128], q[128];
    int bad = 0;
    for (int i = 0; i < nfiles; i++) {
        path_of(p, sizeof(p), dir, "f", i);
        int fd = open(p, O_CREAT | O_RDWR, 0644);
        if (fd < 0) { bad++; continue; }
        close(fd);
        if (i % 2) {
            path_of(q, sizeof(q), dir, "r", i);
            if (rename(p, q) != 0) bad++;
        }
    }
    return bad;
}

// Look up, open and remove every file create_and_rename() left.
static void lookup_and_remove(const char *dir)
{
    char p[128];
    struct stat st;
    for (int i = 0; i < nfiles; i++) {
        path_of(p, sizeof(p), dir, i % 2 ? "r" : "f", i);
        check(stat(p, &st) == 0, "stat", p);
        int fd = open(p, O_RDONLY);
        check(fd >= 0, "open", p);
        if (fd >= 0) close(fd);
        check(unlink(p) == 0, "unlink", p);
    }
    check(rmdir(dir) == 0, "rmdir", dir);
}

static int wait_ok(pid_t pid, const char *what)
{
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status)) {
        printf("FAIL: %s child status=0x%x\n", what, status);
        failures++;
        return 0;
    }
    return 1;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    const char *base = argc > 1 ? argv[1] : "/tmp";
    int rounds = argc > 2 ? atoi(argv[2]) : 20;
    char dir[96];
    printf("=== tst-fork-dentry-share base=%s rounds=%d ===\n", base, rounds);

    for (int r = 0; r < rounds && !failures; r++) {
        // Phase A: child-created dentries, used by the parent after the child is gone.
        snprintf(dir, sizeof(dir), "%s/fds-a%d", base, r);
        check(mkdir(dir, 0755) == 0, "mkdir", dir);
        pid_t pid = fork();
        if (pid == 0) {
            _exit(create_and_rename(dir) ? 1 : 0);
        }
        if (wait_ok(pid, "phase A")) {
            lookup_and_remove(dir);
        }

        // Phase B: parent-created dentries (after fork), used by the child.
        snprintf(dir, sizeof(dir), "%s/fds-b%d", base, r);
        check(mkdir(dir, 0755) == 0, "mkdir", dir);
        int go[2];
        check(pipe(go) == 0, "pipe", "");
        pid = fork();
        if (pid == 0) {
            char c;
            close(go[1]);
            if (read(go[0], &c, 1) != 1) _exit(2);
            char p[128];
            struct stat st;
            for (int i = 0; i < nfiles; i++) {
                path_of(p, sizeof(p), dir, i % 2 ? "r" : "f", i);
                if (stat(p, &st) != 0) _exit(3);
                int fd = open(p, O_RDONLY);
                if (fd < 0) _exit(4);
                close(fd);
            }
            _exit(0);
        }
        close(go[0]);
        check(create_and_rename(dir) == 0, "create", dir);
        check(write(go[1], "g", 1) == 1, "write", "pipe");
        close(go[1]);
        if (wait_ok(pid, "phase B")) {
            lookup_and_remove(dir);
        }

        // Phase C: concurrent children, each in its own directory.
        const int nkids = 4;
        pid_t kids[nkids];
        for (int k = 0; k < nkids; k++) {
            snprintf(dir, sizeof(dir), "%s/fds-c%d-%d", base, r, k);
            check(mkdir(dir, 0755) == 0, "mkdir", dir);
            kids[k] = fork();
            if (kids[k] == 0) {
                _exit(create_and_rename(dir) ? 1 : 0);
            }
        }
        for (int k = 0; k < nkids; k++) {
            snprintf(dir, sizeof(dir), "%s/fds-c%d-%d", base, r, k);
            if (wait_ok(kids[k], "phase C")) {
                lookup_and_remove(dir);
            }
        }
    }

    if (failures == 0)
        printf("PASS: fork children and parent share dentries across %d rounds\n", rounds);
    printf("=== tst-fork-dentry-share done: %d failures ===\n", failures);
    return failures ? 1 : 0;
}
