/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * POSIX per-process file descriptor table across fork().
 *
 * POSIX (and Linux) say that after fork() the child gets a COPY of the parent's
 * descriptor table:
 *
 *   - each open fd number in the child refers to the SAME open file
 *     description, so the file offset, status flags and locks are shared (a
 *     read() in the child advances the parent's offset);
 *   - but the table ENTRIES are independent, so close() in the child does not
 *     close the parent's fd, dup2()/fcntl(F_SETFD)/O_CLOEXEC changes are
 *     private, and the child may reuse a number the parent still holds;
 *   - FD_CLOEXEC is a property of the DESCRIPTOR (private per process), while
 *     O_NONBLOCK and the offset live on the FILE DESCRIPTION (shared).
 *
 * Before the per-process descriptor table, OSv had ONE GLOBAL table
 * (fs/vfs/kern_descrip.cc gfdt[]) shared by every "process", and fork() faked
 * inheritance with per-address-space bookkeeping plus three special cases in
 * fdclose():
 *   fork_child_close_inherited_fd(), fork_owner_close_inherited_fd(),
 *   fork_child_owns_fd()
 * The last of those made a child's close() of a parent-owned fd a SILENT NO-OP,
 * so a child could not free a descriptor number at all.  This test covers each
 * POSIX rule separately; on the old code T1, T3, T4 and T6 fail (T6 hangs or
 * reports the parent's death-watch broken), while T2 and T5 pass and must KEEP
 * passing -- they are the half a naive "just dup everything" fix breaks.
 *
 * Each check prints "ok N - ..." or "FAIL N - ..." and the summary line is
 * "SUMMARY: n/6 passed".
 *
 * To run (CONF_fork=y build):
 *   ./scripts/build conf_fork=1 fs=rofs image=tests
 *   ./scripts/run.py -c 2 -e /tests/tst-fork-fdtable.so
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

static int g_pass = 0;
static int g_total = 0;

static void check(int n, bool ok, const char *what)
{
    g_total++;
    if (ok) {
        g_pass++;
        printf("ok %d - %s\n", n, what);
    } else {
        printf("FAIL %d - %s\n", n, what);
    }
    fflush(stdout);
}

// Write a file with @len bytes of known content and return its path.
static const char *make_file(const char *path, size_t len)
{
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0) {
        printf("# setup: open(%s) failed errno=%d\n", path, errno);
        return nullptr;
    }
    for (size_t i = 0; i < len; i++) {
        char c = 'A' + (char)(i % 26);
        if (write(fd, &c, 1) != 1) {
            printf("# setup: write failed errno=%d\n", errno);
            close(fd);
            return nullptr;
        }
    }
    close(fd);
    return path;
}

// A child result is passed back through its exit status (0 = ok, 1 = not ok).
// Returns the child's WEXITSTATUS, or -1 if it did not exit normally.
static int reap(pid_t pid)
{
    int st = 0;
    if (waitpid(pid, &st, 0) != pid) {
        return -1;
    }
    return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

/*
 * T1: close() in the child does NOT close the parent's fd.
 *
 * The core POSIX rule and the one the old shared table could not honor: the
 * child's close() either tore the parent's slot down (early OSv), or was turned
 * into a silent no-op by fork_child_owns_fd() (HEAD before this change).
 */
static void t1_child_close_does_not_close_parent()
{
    const char *path = "/tmp/fdt-t1";
    if (!make_file(path, 64)) { check(1, false, "setup"); return; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { check(1, false, "parent open"); return; }

    pid_t pid = fork();
    if (pid == 0) {
        // Child: close the inherited fd.  This must affect only the child.
        int rc = close(fd);
        // The child's own fd must now be gone: a second close must fail EBADF.
        int rc2 = close(fd);
        _exit((rc == 0 && rc2 < 0 && errno == EBADF) ? 0 : 1);
    }
    if (pid < 0) { check(1, false, "fork"); close(fd); return; }

    int crc = reap(pid);

    // The parent's fd must still work.
    char buf[8];
    ssize_t n = pread(fd, buf, sizeof(buf), 0);
    bool parent_ok = (n == (ssize_t)sizeof(buf) && buf[0] == 'A');
    close(fd);
    unlink(path);

    if (crc != 0) {
        printf("# child close()/EBADF check failed (rc=%d): the child could not "
               "free its own descriptor\n", crc);
    }
    if (!parent_ok) {
        printf("# parent read after child close failed n=%zd errno=%d\n", n, errno);
    }
    check(1, crc == 0 && parent_ok,
          "close() in child leaves parent's fd open, and frees the child's");
}

/*
 * T2: the file OFFSET is shared.
 *
 * This is the half that must NOT change: parent and child share the open file
 * description, so a read() in the child advances the offset the parent then
 * reads from.  A naive "give the child its own copy of everything" fix breaks
 * exactly this.
 */
static void t2_offset_is_shared()
{
    const char *path = "/tmp/fdt-t2";
    if (!make_file(path, 64)) { check(2, false, "setup"); return; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { check(2, false, "parent open"); return; }

    pid_t pid = fork();
    if (pid == 0) {
        // Child: consume the first 10 bytes ("ABCDEFGHIJ").
        char b[10];
        ssize_t n = read(fd, b, sizeof(b));
        _exit((n == (ssize_t)sizeof(b) && b[0] == 'A' && b[9] == 'J') ? 0 : 1);
    }
    if (pid < 0) { check(2, false, "fork"); close(fd); return; }

    int crc = reap(pid);

    // The parent's read must continue where the CHILD left off: byte 10 = 'K'.
    char b[4];
    ssize_t n = read(fd, b, sizeof(b));
    off_t pos = lseek(fd, 0, SEEK_CUR);
    close(fd);
    unlink(path);

    bool shared = (n == (ssize_t)sizeof(b) && b[0] == 'K' && pos == 14);
    if (!shared) {
        printf("# parent read after child's 10 bytes: n=%zd first=0x%02x pos=%lld "
               "(expected n=4 first='K' pos=14) -- the offset is NOT shared\n",
               n, (unsigned char)b[0], (long long)pos);
    }
    check(2, crc == 0 && shared,
          "file offset is shared: parent's read continues from child's position");
}

/*
 * T3: independent numbering.
 *
 * The child closes an fd, opens a different file, and must be able to get THAT
 * SAME NUMBER back while the parent still holds its own (different) file at
 * that number.  On the old shared table the number stayed occupied by the
 * parent's file, so the child's open() got a different one -- and its close()
 * had been a no-op anyway.
 */
static void t3_independent_numbering()
{
    const char *pa = "/tmp/fdt-t3a";
    const char *pb = "/tmp/fdt-t3b";
    if (!make_file(pa, 32)) { check(3, false, "setup"); return; }
    // File B starts with 'Z' so the two are distinguishable by one byte.
    int bfd = open(pb, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (bfd < 0) { check(3, false, "setup B"); return; }
    if (write(bfd, "ZZZZ", 4) != 4) { check(3, false, "setup B write"); close(bfd); return; }
    close(bfd);

    int fd = open(pa, O_RDONLY);
    if (fd < 0) { check(3, false, "parent open"); return; }

    pid_t pid = fork();
    if (pid == 0) {
        // Child: free the number, then claim it for a DIFFERENT file.
        if (close(fd) != 0) {
            printf("# child: close(%d) failed errno=%d\n", fd, errno);
            _exit(1);
        }
        int nfd = open(pb, O_RDONLY);
        if (nfd != fd) {
            printf("# child: reopened as fd %d, wanted the freed number %d "
                   "(the child cannot reuse a number the parent holds)\n", nfd, fd);
            _exit(1);
        }
        // ... and it must be file B, not the parent's file A.
        char c = 0;
        if (read(nfd, &c, 1) != 1 || c != 'Z') {
            printf("# child: fd %d reads 0x%02x, expected 'Z' (file B)\n", nfd, (unsigned char)c);
            _exit(1);
        }
        _exit(0);
    }
    if (pid < 0) { check(3, false, "fork"); close(fd); return; }

    int crc = reap(pid);

    // The parent's same number must still be file A.
    char c = 0;
    bool parent_ok = (pread(fd, &c, 1, 0) == 1 && c == 'A');
    if (!parent_ok) {
        printf("# parent: fd %d reads 0x%02x, expected 'A' (file A)\n", fd, (unsigned char)c);
    }
    close(fd);
    unlink(pa);
    unlink(pb);

    check(3, crc == 0 && parent_ok,
          "child reuses a closed fd number for its own file; parent's number unchanged");
}

/*
 * T4: FD_CLOEXEC is private to the descriptor table.
 *
 * FD_CLOEXEC is per-DESCRIPTOR state, so a child setting it must not be visible
 * to the parent.  OSv used to store it as O_CLOEXEC in file::f_flags -- state
 * on the shared open file description -- so the child's F_SETFD changed the
 * parent's flag too (and the same bug made two dup()ed fds share it).
 */
static void t4_cloexec_is_private()
{
    const char *path = "/tmp/fdt-t4";
    if (!make_file(path, 8)) { check(4, false, "setup"); return; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) { check(4, false, "parent open"); return; }

    // Parent starts with FD_CLOEXEC clear.
    if (fcntl(fd, F_SETFD, 0) != 0) { check(4, false, "parent F_SETFD 0"); close(fd); return; }

    pid_t pid = fork();
    if (pid == 0) {
        // Child: set FD_CLOEXEC, and confirm it reads back set in the child.
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
            printf("# child: F_SETFD failed errno=%d\n", errno);
            _exit(1);
        }
        int got = fcntl(fd, F_GETFD);
        _exit((got >= 0 && (got & FD_CLOEXEC)) ? 0 : 1);
    }
    if (pid < 0) { check(4, false, "fork"); close(fd); return; }

    int crc = reap(pid);

    int pflag = fcntl(fd, F_GETFD);
    // The parent's flag must still be clear.
    bool parent_clear = (pflag >= 0 && !(pflag & FD_CLOEXEC));
    if (!parent_clear) {
        printf("# parent F_GETFD = 0x%x after child set FD_CLOEXEC: expected it "
               "CLEAR (FD_CLOEXEC leaked through the shared file description)\n", pflag);
    }
    // A dup() also gets its own copy of the flag: set it on the original and the
    // duplicate must stay clear (same per-descriptor rule, no fork involved).
    bool dup_private = false;
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0) {
        int d = dup(fd);
        if (d >= 0) {
            int dflag = fcntl(d, F_GETFD);
            dup_private = (dflag >= 0 && !(dflag & FD_CLOEXEC));
            if (!dup_private) {
                printf("# dup()ed fd F_GETFD = 0x%x, expected CLEAR "
                       "(FD_CLOEXEC must not be shared by dup)\n", dflag);
            }
            close(d);
        }
    }
    close(fd);
    unlink(path);

    check(4, crc == 0 && parent_clear && dup_private,
          "FD_CLOEXEC is per-descriptor: private across fork and not shared by dup");
}

/*
 * T5: refcount lifetime.
 *
 * The parent closes its fd while the child still holds one: the child must
 * still be able to use the file description (it holds its own reference).  When
 * the CHILD then exits, the description must be genuinely RELEASED -- observed
 * on a pipe, where the last writer going away makes the reader see EOF.
 */
static void t5_refcount_lifetime()
{
    int pfd[2];
    if (pipe(pfd) != 0) { check(5, false, "pipe"); return; }
    // pfd[0] = read end (kept by the parent), pfd[1] = write end.

    pid_t pid = fork();
    if (pid == 0) {
        // Child: the parent will close ITS write end while we still hold ours.
        // Our write must still succeed (our reference keeps the description
        // alive), then we exit so the last writer reference goes away.
        usleep(200000);
        ssize_t n = write(pfd[1], "x", 1);
        if (n != 1) {
            printf("# child: write on inherited pipe failed n=%zd errno=%d "
                   "(the parent's close destroyed the shared description)\n", n, errno);
            _exit(1);
        }
        close(pfd[1]);
        close(pfd[0]);
        _exit(0);
    }
    if (pid < 0) { check(5, false, "fork"); close(pfd[0]); close(pfd[1]); return; }

    // Parent: drop OUR write end.  The child's copy must keep the pipe writable.
    close(pfd[1]);

    char c = 0;
    ssize_t n = read(pfd[0], &c, 1);
    bool got_byte = (n == 1 && c == 'x');
    if (!got_byte) {
        printf("# parent: read after parent-close/child-write n=%zd errno=%d "
               "(expected the child's byte)\n", n, errno);
    }

    int crc = reap(pid);

    // Now that the child is gone, ALL write references are dropped, so the read
    // end must see EOF.  If the child's table had leaked its reference, this
    // would block forever instead -- so bound it with poll().
    bool got_eof = false;
    struct pollfd p = { pfd[0], POLLIN, 0 };
    if (poll(&p, 1, 5000) > 0) {
        char d = 0;
        ssize_t z = read(pfd[0], &d, 1);
        got_eof = (z == 0);
        if (!got_eof) {
            printf("# parent: expected EOF after child exit, got n=%zd errno=%d\n", z, errno);
        }
    } else {
        printf("# parent: no EOF within 5s after child exit -- the child's "
               "descriptor table did not release its reference\n");
    }
    close(pfd[0]);

    check(5, crc == 0 && got_byte && got_eof,
          "refcount lifetime: child outlives parent's close, then release is real (EOF)");
}

/*
 * T6: the PostgreSQL regression the fdclose() special cases were papering over.
 *
 * PostgreSQL's postmaster creates a "death watch" pipe and every backend
 * inherits it; a backend's ClosePostmasterPorts() then close()s the
 * postmaster-owned fds it does not need.  On the single shared table that
 * close() nulled the postmaster's own slot, corrupting the postmaster -- which
 * is why fdclose() grew fork_child_owns_fd() to make such a close a NO-OP.
 *
 * Structure here mirrors it: parent (postmaster) holds the death-watch pipe,
 * forks a child (backend) that closes its inherited copies exactly as
 * ClosePostmasterPorts() does, and then the parent's death watch must STILL
 * work -- i.e. the parent can still poll its read end and see the pipe stay
 * open (no EOF, because the parent still holds the write end), and can still
 * write and read its own bytes through it.  With a correct per-process table
 * this needs no special case at all.
 */
static void t6_postmaster_death_watch()
{
    int watch[2];
    if (pipe(watch) != 0) { check(6, false, "pipe"); return; }

    // A second pipe the child uses to report that it has done its closes, so
    // the parent's check happens strictly afterwards.
    int sync_pipe[2];
    if (pipe(sync_pipe) != 0) {
        check(6, false, "sync pipe");
        close(watch[0]); close(watch[1]);
        return;
    }

    pid_t pid = fork();
    if (pid == 0) {
        // "Backend": ClosePostmasterPorts() -- close the inherited death-watch
        // fds.  Both must report success (they are this process's descriptors).
        int r0 = close(watch[0]);
        int r1 = close(watch[1]);
        char msg = (r0 == 0 && r1 == 0) ? 'y' : 'n';
        ssize_t w = write(sync_pipe[1], &msg, 1);
        close(sync_pipe[0]);
        close(sync_pipe[1]);
        _exit((w == 1 && msg == 'y') ? 0 : 1);
    }
    if (pid < 0) {
        check(6, false, "fork");
        close(watch[0]); close(watch[1]);
        close(sync_pipe[0]); close(sync_pipe[1]);
        return;
    }

    // Parent (postmaster): wait for the backend to finish its closes.
    char msg = 0;
    bool child_closed_ok = false;
    struct pollfd sp = { sync_pipe[0], POLLIN, 0 };
    if (poll(&sp, 1, 5000) > 0 && read(sync_pipe[0], &msg, 1) == 1) {
        child_closed_ok = (msg == 'y');
        if (!child_closed_ok) {
            printf("# backend could not close its inherited death-watch fds\n");
        }
    } else {
        printf("# backend never reported (poll/read on sync pipe failed)\n");
    }

    // The postmaster's death watch must be INTACT: no EOF on the read end
    // (the postmaster still holds the write end), and it still carries data.
    struct pollfd wp = { watch[0], POLLIN, 0 };
    int pr = poll(&wp, 1, 200);
    bool no_spurious_eof = !(pr > 0 && (wp.revents & POLLHUP));
    if (!no_spurious_eof) {
        printf("# postmaster's death-watch read end reports HUP (revents=0x%x): the "
               "backend's close tore down the postmaster's own pipe\n", wp.revents);
    }

    bool still_usable = false;
    if (write(watch[1], "P", 1) == 1) {
        char c = 0;
        still_usable = (read(watch[0], &c, 1) == 1 && c == 'P');
    }
    if (!still_usable) {
        printf("# postmaster could no longer use its own death-watch pipe "
               "(errno=%d)\n", errno);
    }

    int crc = reap(pid);
    close(watch[0]);
    close(watch[1]);
    close(sync_pipe[0]);
    close(sync_pipe[1]);

    check(6, crc == 0 && child_closed_ok && no_spurious_eof && still_usable,
          "backend's ClosePostmasterPorts() does not break the postmaster's death watch");
}

int main(int argc, char **argv)
{
    printf("tst-fork-fdtable: POSIX per-process fd table across fork()\n");
    fflush(stdout);

    t1_child_close_does_not_close_parent();
    t2_offset_is_shared();
    t3_independent_numbering();
    t4_cloexec_is_private();
    t5_refcount_lifetime();
    t6_postmaster_death_watch();

    printf("SUMMARY: %d/%d passed\n", g_pass, g_total);
    fflush(stdout);
    return g_pass == g_total ? 0 : 1;
}
