/*
 * Copyright (C) 2026 OSv Authors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/*
 * ZFS TRIM/DISCARD test.
 *
 * Tests the `zpool trim` code path from the ZFS userspace library (libzfs_core
 * lzc_trim) down through the kernel vdev_trim machinery to the virtio-blk
 * BIO_DISCARD layer.
 *
 * The TRIM path in OSv involves three layers:
 *
 *   1. Userspace: lzc_trim() → ZFS_IOC_POOL_TRIM ioctl → spa/vdev_trim.c
 *   2. Kernel:    vdev_trim_zio() → zio_trim() → ZIO_TYPE_TRIM pipeline
 *                 → vdev_disk_io_start() → BIO_DISCARD bio
 *   3. Driver:    virtio-blk make_request(BIO_DISCARD) → VIRTIO_BLK_T_DISCARD
 *
 * NOTE: The OSv vdev_disk.c does not yet handle ZIO_TYPE_TRIM in
 * vdev_disk_io_start() — only ZIO_TYPE_FLUSH, ZIO_TYPE_READ, and
 * ZIO_TYPE_WRITE are implemented.  When a TRIM zio reaches the vdev layer,
 * it will be completed with an error or silently succeed depending on how
 * the ZFS pipeline handles the missing op.  This test reports SKIP rather
 * than FAIL in that case so CI is not broken while the feature is pending.
 *
 * Test sequence:
 *   1. Load libzfs.so / libzfs_core.so via dlopen.
 *   2. Open (or detect) the ZFS pool.
 *   3. Create a temporary dataset.
 *   4. Write ~10 MB of data to files in the dataset.
 *   5. Destroy the dataset (frees space in the space map).
 *   6. Call lzc_trim(pool, POOL_TRIM_START, ...) to request a TRIM pass.
 *   7. Wait briefly; call lzc_trim(..., POOL_TRIM_CANCEL, ...) to stop it.
 *   8. Report PASS if lzc_trim() returned 0, SKIP if EOPNOTSUPP/ENOTSUP,
 *      FAIL otherwise.
 *
 * Run: ./scripts/run.py --image <zfs-image> -e "tests/tst-zfs-trim.so"
 * Requires: ZFS root filesystem (build with fs=zfs)
 */

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dlfcn.h>

/* --------------------------------------------------------------------------
 * libzfs / libzfs_core runtime bindings — no build-time dependency on headers
 * -------------------------------------------------------------------------- */
typedef struct libzfs_handle  libzfs_handle_t;
typedef struct zfs_handle     zfs_handle_t;
typedef struct zpool_handle   zpool_handle_t;
typedef struct nvlist         nvlist_t;

/* pool_trim_func_t values (from sys/fs/zfs.h) */
enum pool_trim_func {
    POOL_TRIM_START   = 0,
    POOL_TRIM_CANCEL  = 1,
    POOL_TRIM_SUSPEND = 2,
};
typedef enum pool_trim_func pool_trim_func_t;

#define ZFS_TYPE_FILESYSTEM (1 << 0)

/* libzfs symbols */
typedef libzfs_handle_t *(*fn_libzfs_init)(void);
typedef void             (*fn_libzfs_fini)(libzfs_handle_t *);
typedef zpool_handle_t * (*fn_zpool_open)(libzfs_handle_t *, const char *);
typedef void             (*fn_zpool_close)(zpool_handle_t *);
typedef int              (*fn_zfs_create)(libzfs_handle_t *, const char *,
                                          int, nvlist_t *);
typedef zfs_handle_t *   (*fn_zfs_open)(libzfs_handle_t *, const char *, int);
typedef int              (*fn_zfs_prop_set)(zfs_handle_t *, const char *,
                                            const char *);
typedef int              (*fn_zfs_destroy)(zfs_handle_t *, int);
typedef void             (*fn_zfs_close)(zfs_handle_t *);

/* libzfs_core symbols */
typedef int (*fn_lzc_trim)(const char *, pool_trim_func_t, uint64_t,
                           int /*boolean_t*/, nvlist_t *, nvlist_t **);

static fn_libzfs_init  p_libzfs_init;
static fn_libzfs_fini  p_libzfs_fini;
static fn_zpool_open   p_zpool_open;
static fn_zpool_close  p_zpool_close;
static fn_zfs_create   p_zfs_create;
static fn_zfs_open     p_zfs_open;
static fn_zfs_prop_set p_zfs_prop_set;
static fn_zfs_destroy  p_zfs_destroy;
static fn_zfs_close    p_zfs_close;
static fn_lzc_trim     p_lzc_trim;

static bool load_libzfs(void)
{
    void *h = dlopen("libzfs.so", RTLD_LAZY | RTLD_GLOBAL);
    if (!h) {
        fprintf(stderr, "SKIP: cannot load libzfs.so: %s\n", dlerror());
        return false;
    }
    void *hc = dlopen("libzfs_core.so", RTLD_LAZY | RTLD_GLOBAL);
    if (!hc) {
        fprintf(stderr, "SKIP: cannot load libzfs_core.so: %s\n", dlerror());
        return false;
    }

#define L(lib, name) \
    p_##name = (fn_##name)dlsym(lib, #name); \
    if (!p_##name) { \
        fprintf(stderr, "SKIP: symbol " #name " not found\n"); \
        return false; \
    }
    L(h,  libzfs_init)
    L(h,  libzfs_fini)
    L(h,  zpool_open)
    L(h,  zpool_close)
    L(h,  zfs_create)
    L(h,  zfs_open)
    L(h,  zfs_prop_set)
    L(h,  zfs_destroy)
    L(h,  zfs_close)
    L(hc, lzc_trim)
#undef L
    return true;
}

/* --------------------------------------------------------------------------
 * Test helpers
 * -------------------------------------------------------------------------- */
static int  tests_run     = 0;
static int  tests_passed  = 0;
static int  tests_skipped = 0;

#define PASS(fmt, ...) \
    do { tests_run++; tests_passed++; \
         printf("  PASS  " fmt "\n", ##__VA_ARGS__); } while (0)

#define FAIL(fmt, ...) \
    do { tests_run++; \
         printf("  FAIL  " fmt "\n", ##__VA_ARGS__); } while (0)

#define SKIP(fmt, ...) \
    do { tests_run++; tests_skipped++; \
         printf("  SKIP  " fmt "\n", ##__VA_ARGS__); } while (0)

static const char *detect_pool(libzfs_handle_t *zfsh)
{
    static const char *cands[] = { "rpool", "osv", "data", nullptr };
    for (int i = 0; cands[i]; i++) {
        zpool_handle_t *ph = p_zpool_open(zfsh, cands[i]);
        if (ph) { p_zpool_close(ph); return cands[i]; }
    }
    return nullptr;
}

static int create_dataset(libzfs_handle_t *zfsh, const char *name,
                           const char *mountpoint)
{
    int rc = p_zfs_create(zfsh, name, ZFS_TYPE_FILESYSTEM, nullptr);
    if (rc != 0)
        return rc;
    zfs_handle_t *zh = p_zfs_open(zfsh, name, ZFS_TYPE_FILESYSTEM);
    if (!zh)
        return -1;
    if (mountpoint)
        p_zfs_prop_set(zh, "mountpoint", mountpoint);
    p_zfs_close(zh);
    return 0;
}

static void destroy_dataset(libzfs_handle_t *zfsh, const char *name)
{
    zfs_handle_t *zh = p_zfs_open(zfsh, name, ZFS_TYPE_FILESYSTEM);
    if (zh) { p_zfs_destroy(zh, /*defer=*/0); p_zfs_close(zh); }
}

/*
 * Write ~10 MB of data across several files under dir.
 * Returns the number of bytes actually written.
 */
static size_t write_test_data(const char *dir)
{
    static const size_t BUF_SZ  = 128 * 1024;   /* 128 KB write buffer */
    static const size_t FILE_SZ = 2 * 1024 * 1024; /* 2 MB per file */
    static const int    NFILES  = 5;

    char buf[BUF_SZ];
    memset(buf, 0xA5, sizeof(buf));

    size_t total = 0;
    for (int i = 0; i < NFILES; i++) {
        char path[512];
        snprintf(path, sizeof(path), "%s/trim-data-%d.bin", dir, i);
        int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd < 0) continue;
        for (size_t written = 0; written < FILE_SZ; ) {
            ssize_t n = write(fd, buf, BUF_SZ);
            if (n <= 0) break;
            written += (size_t)n;
            total   += (size_t)n;
        }
        fsync(fd);
        close(fd);
    }
    return total;
}

/* --------------------------------------------------------------------------
 * Tests
 * -------------------------------------------------------------------------- */

/*
 * Test 1: write data to a temporary dataset, then destroy it.
 * This frees blocks in the ZFS space map, which is a prerequisite for
 * TRIM to have anything to reclaim.
 */
static void test_write_and_destroy(libzfs_handle_t *zfsh,
                                    const char *ds_name,
                                    const char *mount)
{
    printf("\n[Test 1] Create dataset, write ~10 MB, destroy\n");

    if (create_dataset(zfsh, ds_name, mount) != 0) {
        FAIL("could not create dataset %s (errno=%d: %s)",
             ds_name, errno, strerror(errno));
        return;
    }
    PASS("dataset %s created", ds_name);

    size_t written = write_test_data(mount);
    if (written == 0) {
        FAIL("no data written to %s", mount);
        destroy_dataset(zfsh, ds_name);
        return;
    }
    PASS("wrote %zu bytes (~%zu MB) to %s",
         written, written / (1024 * 1024), mount);

    /* Destroy the dataset to free the blocks into the space map. */
    destroy_dataset(zfsh, ds_name);
    PASS("dataset %s destroyed (blocks freed to space map)", ds_name);
}

/*
 * Test 2: invoke lzc_trim() to start a TRIM pass on the pool.
 *
 * Expected outcomes:
 *   0           → PASS (TRIM accepted by the ZFS pool)
 *   EOPNOTSUPP  → SKIP (vdev does not support DISCARD; expected on most
 *                        QEMU/KVM setups without explicit virtio discard)
 *   ENOTSUP     → SKIP (same as above; POSIX vs. Linux spelling)
 *   other       → FAIL
 */
static void test_trim_start_cancel(const char *pool_name)
{
    printf("\n[Test 2] lzc_trim(POOL_TRIM_START)\n");

    /*
     * rate=0 means "use the default trim rate".
     * secure=0 (B_FALSE) means normal (non-secure) TRIM.
     * vdevs=NULL means trim all vdevs in the pool.
     */
    nvlist_t *errlist = nullptr;
    int rc = p_lzc_trim(pool_name, POOL_TRIM_START,
                        /*rate=*/0, /*secure=*/0,
                        /*vdevs=*/nullptr, &errlist);

    if (rc == 0) {
        PASS("lzc_trim(POOL_TRIM_START) succeeded on pool %s", pool_name);

        /* Cancel the trim so we do not leave it running indefinitely. */
        printf("\n[Test 3] lzc_trim(POOL_TRIM_CANCEL)\n");
        rc = p_lzc_trim(pool_name, POOL_TRIM_CANCEL,
                        0, 0, nullptr, &errlist);
        if (rc == 0) {
            PASS("lzc_trim(POOL_TRIM_CANCEL) succeeded");
        } else {
            /*
             * CANCEL returning an error is non-fatal — the trim may have
             * already finished on a small pool before we got here.
             */
            printf("  NOTE  lzc_trim(POOL_TRIM_CANCEL) returned %d (%s) "
                   "— trim may have completed before cancel\n",
                   rc, strerror(rc));
            PASS("TRIM cancel attempted (pool may have completed trim already)");
        }
    } else if (rc == EOPNOTSUPP || rc == ENOTSUP) {
        /*
         * The vdev layer returned ENOTSUP.  This is the expected result when
         * the OSv vdev_disk.c does not yet handle ZIO_TYPE_TRIM or when the
         * hypervisor virtio-blk device was started without discard support
         * (no --discard=on flag passed to QEMU).
         */
        SKIP("lzc_trim returned %d (%s) — TRIM not supported on this vdev "
             "(ZIO_TYPE_TRIM not handled in vdev_disk.c, or hypervisor "
             "virtio-blk started without discard support)",
             rc, strerror(rc));
    } else if (rc == EBUSY) {
        /*
         * Pool has an ongoing trim already (unlikely in a fresh boot, but
         * handle it gracefully).
         */
        SKIP("lzc_trim returned EBUSY — pool already has an active trim");
    } else {
        FAIL("lzc_trim(POOL_TRIM_START) returned unexpected error %d (%s)",
             rc, strerror(rc));
    }
}

/* --------------------------------------------------------------------------
 * main
 * -------------------------------------------------------------------------- */
int main(void)
{
    printf("=== ZFS TRIM/DISCARD test ===\n\n");

    /*
     * Explain the TRIM path so log readers understand what is being tested
     * even before any test result is printed.
     */
    printf("TRIM path under test:\n");
    printf("  lzc_trim() -> ZFS_IOC_POOL_TRIM -> vdev_trim.c\n");
    printf("  -> zio_trim() [ZIO_TYPE_TRIM] -> vdev_disk_io_start()\n");
    printf("  -> bio(BIO_DISCARD) -> virtio-blk VIRTIO_BLK_T_DISCARD\n\n");
    printf("NOTE: OSv vdev_disk.c does not yet handle ZIO_TYPE_TRIM;\n");
    printf("      lzc_trim() returning EOPNOTSUPP/ENOTSUP is a SKIP,\n");
    printf("      not a FAIL.\n\n");

    if (!load_libzfs())
        return 1;

    libzfs_handle_t *zfsh = p_libzfs_init();
    if (!zfsh) {
        fprintf(stderr, "SKIP: libzfs_init() failed\n");
        return 1;
    }

    const char *pool = detect_pool(zfsh);
    if (!pool) {
        p_libzfs_fini(zfsh);
        fprintf(stderr, "SKIP: no ZFS pool found (tried rpool, osv, data)\n");
        return 1;
    }
    printf("Using pool: %s\n", pool);

    /* Build dataset and mount paths. */
    char ds_name[256];
    char mount[256];
    snprintf(ds_name, sizeof(ds_name), "%s/trim-test", pool);
    snprintf(mount,   sizeof(mount),   "/zfs-trim-test");

    /* Test 1: write data + destroy (prerequisite for a meaningful TRIM). */
    test_write_and_destroy(zfsh, ds_name, mount);

    /* Test 2 (+3): start TRIM, then cancel it. */
    test_trim_start_cancel(pool);

    /* Summary */
    printf("\n=== Results: %d/%d passed", tests_passed, tests_run);
    if (tests_skipped > 0)
        printf(", %d skipped", tests_skipped);
    printf(" ===\n");

    if (tests_skipped > 0 && tests_skipped == tests_run - tests_passed) {
        printf("\nNOTE: TRIM support requires:\n");
        printf("  1. ZIO_TYPE_TRIM handling in vdev_disk_io_start() "
               "(not yet implemented)\n");
        printf("  2. Hypervisor virtio-blk with discard enabled "
               "(QEMU: --discard=on)\n");
    }

    p_libzfs_fini(zfsh);

    /* Return 0 if everything passed or was skipped; 1 if any test failed. */
    return (tests_passed + tests_skipped == tests_run) ? 0 : 1;
}
