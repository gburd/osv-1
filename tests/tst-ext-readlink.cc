/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Regression test for the ext_readlink()/ext_readdir() bounds hardening.
//
// ext-specific: it creates its own symlinks on a writable ext root, so build
// and run it with ext as the root filesystem:
//
//   scripts/build image=tests fs=ext
//   scripts/test.py
//
// The interesting case is the *slow* symlink: a target shorter than
// sizeof(inode->blocks) (60 bytes) is stored inline in the inode and served by
// ext_readlink()'s fast path, which the hardening does not touch.  A target of
// 60 bytes or more is stored in a data block and goes through the guarded
// malloc(block_size) + ext_internal_read() path, so the test uses both lengths
// and checks that neither is truncated or corrupted.
//
// Crafting an inode with i_size > block_size (the actual overflow) needs a
// debugfs-built image and cannot be done from inside the guest, so that case is
// covered by the reasoning in the commit message, not here.  What this test
// pins down is that the guards do not break any legitimate symlink, including
// the longest one ext can store.

#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>

#include <cassert>
#include <string>

// Create a symlink at @path pointing at @target, then read it back and require
// an exact round-trip.
static void check_symlink(const std::string& path, const std::string& target)
{
    unlink(path.c_str());
    if (symlink(target.c_str(), path.c_str()) != 0) {
        fprintf(stderr, "symlink(%s -> %zu bytes) FAILED: %s\n",
                path.c_str(), target.size(), strerror(errno));
        assert(false);
    }

    char buf[PATH_MAX];
    memset(buf, 0, sizeof(buf));
    ssize_t n = readlink(path.c_str(), buf, sizeof(buf) - 1);
    if (n < 0) {
        fprintf(stderr, "readlink(%s) FAILED: %s\n",
                path.c_str(), strerror(errno));
        assert(false);
    }
    buf[n] = 0;
    fprintf(stderr, "readlink(%s) = %zd bytes (expected %zu)\n",
            path.c_str(), n, target.size());
    assert(n == (ssize_t)target.size());
    assert(target == buf);

    unlink(path.c_str());
}

int main(int argc, char **argv)
{
    fprintf(stderr, "Running ext-readlink tests\n");

    // Default to the (writable) ext root; an optional argument lets the same
    // binary be pointed at another directory, e.g. a mounted ext image at
    // /data, or a host filesystem when sanity-checking the test itself.
    const std::string base = (argc > 1) ? argv[1] : "";

    // Fast path: target < sizeof(inode->blocks) (60), stored inline.
    check_symlink(base + "/tst-ext-link-fast", "/realfile");

    // Slow path: >= 60 bytes, so the target is stored in a data block and read
    // back through the guarded malloc(block_size) + ext_internal_read() branch
    // that this change hardens.  64 bytes, just over the inline limit.
    check_symlink(base + "/tst-ext-link-slow", std::string(64, 'a'));

    // Still the slow path, at the longest target a single block can hold on the
    // smallest supported block size (1 KiB), to confirm the fsize <= block_size
    // guard does not reject a legitimate long symlink.
    check_symlink(base + "/tst-ext-link-long", "/" + std::string(1022, 'b'));

    // ext_readdir() name clamp: a legitimate 255-byte name (EXT4's maximum)
    // must still be returned intact, i.e. the clamp to sizeof(d_name)-1 = 255
    // does not truncate any name a well-formed image can contain.
    {
        const std::string longest(255, 'c');
        const std::string dir = base + "/tst-ext-rd";
        const std::string path = dir + "/" + longest;
        rmdir(dir.c_str());
        assert(mkdir(dir.c_str(), 0755) == 0);
        int fd = creat(path.c_str(), 0644);
        assert(fd >= 0);
        close(fd);

        DIR *d = opendir(dir.c_str());
        assert(d != nullptr);
        bool found = false;
        struct dirent *de;
        while ((de = readdir(d)) != nullptr) {
            if (longest == de->d_name) {
                found = true;
            }
            // Whatever the entry, the clamp must leave d_name NUL-terminated
            // within its 256 bytes.
            assert(strlen(de->d_name) < sizeof(de->d_name));
        }
        closedir(d);
        fprintf(stderr, "readdir 255-byte name found: %d\n", (int)found);
        assert(found);

        unlink(path.c_str());
        assert(rmdir(dir.c_str()) == 0);
    }

    fprintf(stderr, "ext-readlink tests PASSED\n");
    return 0;
}
