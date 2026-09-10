/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 *
 * Diagnostic: what does a fork() child actually see of the parent's state?
 * Separates three candidate causes of "child sees EBADF":
 *   A) the child's fd TABLE is wrong/empty          -> table_probe fails
 *   B) the child's plain locals are garbage         -> plain_fd != volatile_fd
 *   C) the child's copied STACK data is wrong       -> magic/array wrong
 */
#include <sys/types.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <cstdio>
#include <cstdlib>

int main()
{
    printf("=== fork child state diagnostic ===\n");
    fflush(stdout);

    // A memory-resident array (address taken -> must live on the stack) and a
    // plain scalar the compiler is free to keep in a callee-saved register.
    volatile int magic = 0x5A5A5A5A;
    int arr[4] = { 11, 22, 33, 44 };
    int *arrp = arr;               // force arr into memory

    int fd = open("/tmp/diag", O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) { printf("setup open failed errno=%d\n", errno); return 1; }
    if (write(fd, "HELLO", 5) != 5) { printf("setup write failed\n"); return 1; }
    lseek(fd, 0, SEEK_SET);

    volatile int vfd = fd;         // same number, but forced to memory
    printf("parent: fd=%d vfd=%d magic=0x%x arr={%d,%d,%d,%d}\n",
           fd, vfd, magic, arrp[0], arrp[1], arrp[2], arrp[3]);
    fflush(stdout);

    pid_t pid = fork();
    if (pid == 0) {
        // (B)/(C): is the child's view of the parent's stack/registers intact?
        printf("child:  plain fd=%d   volatile vfd=%d\n", fd, vfd);
        printf("child:  magic=0x%x (want 0x5a5a5a5a)  arr={%d,%d,%d,%d} (want 11,22,33,44)\n",
               magic, arrp[0], arrp[1], arrp[2], arrp[3]);
        // (A): does the child's fd TABLE contain the inherited descriptor?
        // Use the memory-resident copy so this probes the TABLE, not registers.
        char buf[8] = {0};
        ssize_t n = pread(vfd, buf, 5, 0);
        printf("child:  pread(vfd=%d) n=%zd errno=%d buf=%s\n",
               (int)vfd, n, errno, buf);
        printf("child:  fcntl(vfd,F_GETFD)=%d errno=%d\n", fcntl(vfd, F_GETFD), errno);
        // And a brand-new open in the child, which needs only the child's table.
        int nfd = open("/tmp/diag2", O_CREAT | O_TRUNC | O_RDWR, 0644);
        printf("child:  fresh open() = %d errno=%d\n", nfd, errno);
        fflush(stdout);
        _exit(0);
    }
    if (pid < 0) { printf("fork failed errno=%d\n", errno); return 1; }
    int st = 0;
    waitpid(pid, &st, 0);
    printf("parent: child exited status=%d\n", st);
    printf("parent: after child, magic=0x%x fd=%d\n", magic, fd);
    char b[8] = {0};
    printf("parent: pread own fd n=%zd\n", pread(fd, b, 5, 0));
    close(fd);
    printf("=== diagnostic done ===\n");
    fflush(stdout);
    return 0;
}
