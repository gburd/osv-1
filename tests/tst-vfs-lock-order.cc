/*
 * Copyright (C) 2026 Greg Burd
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

// Lock order between lookup and unlink.
//
// Lookup locks a directory and then, through VOP_LOOKUP() and vget(), the
// vnode of the entry it finds. unlink, rmdir, rename and link must lock in
// the same order, and vget() must not sleep on a vnode lock while holding the
// vnode table lock, which vput() takes with a vnode locked.
//
// A private ramfs mount wraps vop_lookup so that it sleeps while the
// directory is locked, which widens the window in which a lookup holds the
// directory and wants the entry. One thread unlinks and recreates a file,
// another looks it up (lstat, open) through a path that misses the dentry
// cache. A watchdog fails the test if neither thread makes progress for
// 10 seconds: on a deadlocked kernel both threads, and every later vget,
// wait forever.

#include <sys/mount.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <string>
#include <thread>

#include <osv/dentry.h>
#include <osv/mount.h>
#include <osv/vnode.h>

extern "C" int namei(const char *path, struct dentry **dpp);

static struct vnops *ram;
static struct vnops slow_vnops;
static struct vfsops slow_vfsops;

static int slow_lookup(struct vnode *dvp, char *name, struct vnode **vpp)
{
    // dvp is locked here. Give a racing unlink time to lock the entry.
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    return ram->vop_lookup(dvp, name, vpp);
}

static bool mount_fixture(const char *dir)
{
    if (mkdir(dir, 0755) != 0 && errno != EEXIST) {
        printf("FAIL: mkdir %s: %s\n", dir, strerror(errno));
        return false;
    }
    if (mount("none", dir, "ramfs", 0, nullptr) != 0) {
        printf("FAIL: mount %s: %s\n", dir, strerror(errno));
        return false;
    }
    struct dentry *dp;
    if (namei(dir, &dp) != 0) {
        printf("FAIL: namei %s\n", dir);
        return false;
    }
    struct vnode *root = dp->d_vnode;
    struct mount *mp = dp->d_mount;
    ram = root->v_op;
    slow_vnops = *ram;
    slow_vnops.vop_lookup = slow_lookup;
    slow_vfsops = *mp->m_op;
    slow_vfsops.vfs_vnops = &slow_vnops;
    mp->m_op = &slow_vfsops;
    root->v_op = &slow_vnops;
    drele(dp);
    return true;
}

int main()
{
    const char *dir = "/tmp/lock-order";
    if (!mount_fixture(dir)) {
        return 1;
    }
    std::string sub = std::string(dir) + "/d";
    if (mkdir(sub.c_str(), 0755) != 0) {
        printf("FAIL: mkdir %s: %s\n", sub.c_str(), strerror(errno));
        return 1;
    }
    std::string file = sub + "/x";

    std::atomic<bool> stop{false};
    std::atomic<unsigned long> unlinks{0}, lookups{0};

    // Each unlink drops the name's dentry, so the next lookup of it misses
    // the dentry cache and reaches the (slow) filesystem lookup with the
    // directory locked.
    std::thread a([&] {
        while (!stop.load()) {
            int fd = creat(file.c_str(), 0644);
            if (fd >= 0) {
                close(fd);
            }
            unlink(file.c_str());
            unlinks++;
        }
    });
    std::thread b([&] {
        struct stat st;
        while (!stop.load()) {
            lstat(file.c_str(), &st);
            int fd = open(file.c_str(), O_RDONLY);
            if (fd >= 0) {
                close(fd);
            }
            lookups++;
        }
    });

    const int run_s = 20, stall_s = 10;
    unsigned long last_u = 0, last_l = 0;
    int still = 0;
    for (int t = 0; t < run_s; t++) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        unsigned long u = unlinks.load(), l = lookups.load();
        if (u == last_u && l == last_l) {
            if (++still >= stall_s) {
                printf("FAIL: deadlock: no progress for %d s "
                       "(unlinks %lu, lookups %lu)\n", stall_s, u, l);
                fflush(stdout);
                abort();
            }
        } else {
            still = 0;
        }
        last_u = u;
        last_l = l;
    }
    stop.store(true);
    a.join();
    b.join();
    printf("PASS: no deadlock in %d s (unlinks %lu, lookups %lu)\n",
           run_s, unlinks.load(), lookups.load());
    umount(dir);
    printf("SUMMARY: tst-vfs-lock-order PASS\n");
    return 0;
}
