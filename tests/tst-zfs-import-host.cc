/*
 * Gap 3 verification: import a ZFS pool created on a foreign host (FreeBSD
 * OpenZFS) into OSv and round-trip read/write.
 *
 * The pool lives whole-disk on the second virtio-blk device (/dev/vblk1).
 * sys_mount(dev="/dev/vblkN", data="<dataset>") drives the in-kernel
 * spa_import_rootpool() path -- the same path used to import the root pool
 * at boot -- which avoids the libzfs CLI taskq.
 *
 * Read side  : the host wrote marker.txt and payload.bin into <pool>/data.
 * Write side : OSv writes osv-roundtrip.txt; the host re-imports afterward
 *              and confirms it is visible, proving bidirectional interchange.
 */

#include <sys/stat.h>
#include <sys/mount.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

extern "C" {
int sys_mount(const char *dev, const char *dir, const char *fsname,
              int flags, const void *data);
int sys_umount(const char *path);
}

static int tests = 0, fails = 0;
static void report(bool ok, const char *msg)
{
    ++tests;
    fails += !ok;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", msg);
}

#define POOL_DEV   "/dev/vblk1"
#define DATASET    "gap3/data"
#define MNT        "/gap3"
#define PAYLOAD_SZ (8u * 1024u * 1024u)

/* 64-bit FNV-1a; trivially replicated on the host for cross-check. */
static uint64_t fnv1a(const uint8_t *p, size_t n, uint64_t h)
{
    for (size_t i = 0; i < n; i++) {
        h ^= p[i];
        h *= 1099511628211ULL;
    }
    return h;
}

int main(int argc, char **argv)
{
    char buf[8192];

    /* sys_mount() namei()s the mount point, so it must exist first. */
    (void) mkdir(MNT, 0755);

    int ret = sys_mount(POOL_DEV, MNT, "zfs", 0, (void *)DATASET);
    report(ret == 0, "sys_mount host-built pool via spa_import_rootpool");
    if (ret != 0) {
        printf("sys_mount(%s -> %s, ds=%s) failed: %d\n",
               POOL_DEV, MNT, DATASET, ret);
        printf("SUMMARY: %d/%d passed\n", tests - fails, tests);
        return 1;
    }

    /* ---- read side: host-written marker ---- */
    int fd = open(MNT "/marker.txt", O_RDONLY);
    report(fd >= 0, "open host marker.txt");
    if (fd >= 0) {
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n > 0) {
            buf[n] = '\0';
            printf("MARKER: %s", buf);
            report(strstr(buf, "gap3-marker") != NULL &&
                   strstr(buf, "host=nuc") != NULL,
                   "marker content matches host-written data");
        } else {
            report(false, "read marker.txt");
        }
    }

    /* ---- read side: large payload integrity ---- */
    fd = open(MNT "/payload.bin", O_RDONLY);
    report(fd >= 0, "open host payload.bin");
    if (fd >= 0) {
        uint64_t h = 1469598103934665603ULL; /* FNV offset basis */
        size_t total = 0;
        ssize_t n;
        while ((n = read(fd, buf, sizeof(buf))) > 0) {
            h = fnv1a((const uint8_t *)buf, (size_t)n, h);
            total += (size_t)n;
        }
        close(fd);
        printf("PAYLOAD: bytes=%zu fnv1a=0x%016llx\n",
               total, (unsigned long long)h);
        report(total == PAYLOAD_SZ, "payload.bin full size read back");
    }

    /* ---- write side: OSv -> pool, host re-import confirms ---- */
    const char *nonce = (argc > 1) ? argv[1] : "osv-default-nonce";
    fd = open(MNT "/osv-roundtrip.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    report(fd >= 0, "create osv-roundtrip.txt");
    if (fd >= 0) {
        char out[256];
        int len = snprintf(out, sizeof(out),
                           "osv-wrote-this nonce=%s\n", nonce);
        ssize_t w = write(fd, out, len);
        fsync(fd);
        close(fd);
        report(w == len, "write osv-roundtrip.txt");

        /* read back in-guest */
        fd = open(MNT "/osv-roundtrip.txt", O_RDONLY);
        if (fd >= 0) {
            ssize_t r = read(fd, buf, sizeof(buf) - 1);
            close(fd);
            buf[r > 0 ? r : 0] = '\0';
            report(strcmp(buf, out) == 0, "read back osv-roundtrip.txt matches");
        } else {
            report(false, "reopen osv-roundtrip.txt");
        }
    }

    ret = sys_umount(MNT);
    report(ret == 0, "sys_umount (exports pool cleanly)");

    printf("SUMMARY: %d/%d passed\n", tests - fails, tests);
    return fails == 0 ? 0 : 1;
}
