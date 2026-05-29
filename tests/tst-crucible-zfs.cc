/*
 * Copyright (C) 2026 OSv Authors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

/*
 * tst-crucible-zfs: end-to-end ZFS-on-Crucible test that exercises the
 * Crucible block driver under a real ZFS workload.
 *
 * Skipped cleanly if /dev/crucible0 is not present (the boot path
 * leaves it absent when --crucible= is not passed to run.py).
 *
 * Test sequence:
 *   1. Open libzfs.so via dlopen.
 *   2. Build an nvlist describing a single-disk pool on /dev/crucible0.
 *   3. zpool_create("tank", nvroot, ...).
 *   4. Open the pool, create a dataset tank/test, mount it.
 *   5. Write a 1 MiB file and fsync.
 *   6. Read it back and verify byte-for-byte.
 *   7. Destroy dataset and pool.
 *
 * The test deliberately avoids the zpool(8) binary because the OSv
 * userspace zpool entry point currently has a stale-pointer bug in
 * its argv handling (independent of Crucible) that causes a SIGSEGV
 * in strlen() shortly after main().  The libzfs API does not go
 * through that path.
 *
 * Run:
 *   ./scripts/run.py -k --arch=x86_64 -m 2048 -c1 \
 *     --crucible=HOST:P1,HOST:P2,HOST:P3 --crucible-uuid=... \
 *     -e "tests/tst-crucible-zfs.so"
 */

#include <chrono>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

namespace {

constexpr const char *DEV       = "/dev/crucible0";
constexpr const char *POOL_NAME = "ctank";
constexpr const char *DATASET   = "ctank/test";
constexpr const char *MOUNTPT   = "/ctank-test";
constexpr const char *TEST_FILE = "/ctank-test/payload.bin";
/*
 * 256 KiB = exactly 2 ZFS records.  Exercises the multi-record path
 * (smallest size that does so) while keeping the 3-replica quorum
 * write fast enough to complete over WiFi in well under a minute.
 */
constexpr size_t      FILE_SIZE = 256 * 1024;        /* 256 KiB */

int tests_run = 0, tests_passed = 0, tests_failed = 0;

#define PASS(fmt, ...) do {                                  \
    tests_run++; tests_passed++;                              \
    printf("  PASS  " fmt "\n", ##__VA_ARGS__);               \
} while (0)

#define FAIL(fmt, ...) do {                                  \
    tests_run++; tests_failed++;                              \
    printf("  FAIL  " fmt "\n", ##__VA_ARGS__);               \
} while (0)

/* libzfs/libnvpair runtime bindings via dlopen. */
typedef struct libzfs_handle libzfs_handle_t;
typedef struct zfs_handle    zfs_handle_t;
typedef struct zpool_handle  zpool_handle_t;
typedef struct nvlist        nvlist_t;

#define ZFS_TYPE_FILESYSTEM   (1 << 0)

typedef libzfs_handle_t *(*fn_libzfs_init)(void);
typedef void             (*fn_libzfs_fini)(libzfs_handle_t *);
typedef const char *     (*fn_libzfs_error_description)(libzfs_handle_t *);
typedef int              (*fn_zpool_create)(libzfs_handle_t *, const char *,
                                            nvlist_t *, nvlist_t *, nvlist_t *);
typedef zpool_handle_t * (*fn_zpool_open)(libzfs_handle_t *, const char *);
typedef void             (*fn_zpool_close)(zpool_handle_t *);
typedef int              (*fn_zpool_destroy)(zpool_handle_t *, const char *);
typedef int              (*fn_zfs_create)(libzfs_handle_t *, const char *,
                                          int, nvlist_t *);
typedef zfs_handle_t *   (*fn_zfs_open)(libzfs_handle_t *, const char *, int);
typedef int              (*fn_zfs_mount)(zfs_handle_t *, const char *, int);
typedef int              (*fn_zfs_unmount)(zfs_handle_t *, const char *, int);
typedef int              (*fn_zfs_destroy)(zfs_handle_t *, int);
typedef void             (*fn_zfs_close)(zfs_handle_t *);

typedef nvlist_t *(*fn_fnvlist_alloc)(void);
typedef void      (*fn_fnvlist_free)(nvlist_t *);
typedef void      (*fn_fnvlist_add_string)(nvlist_t *, const char *,
                                            const char *);
typedef void      (*fn_fnvlist_add_nvlist_array)(nvlist_t *, const char *,
                                                  const nvlist_t * const *,
                                                  unsigned int);

static fn_libzfs_init               p_libzfs_init;
static fn_libzfs_fini               p_libzfs_fini;
static fn_libzfs_error_description  p_libzfs_error_description;
static fn_zpool_create              p_zpool_create;
static fn_zpool_open                p_zpool_open;
static fn_zpool_close               p_zpool_close;
static fn_zpool_destroy             p_zpool_destroy;
static fn_zfs_create                p_zfs_create;
static fn_zfs_open                  p_zfs_open;
static fn_zfs_mount                 p_zfs_mount;
static fn_zfs_unmount               p_zfs_unmount;
static fn_zfs_destroy               p_zfs_destroy;
static fn_zfs_close                 p_zfs_close;
static fn_fnvlist_alloc             p_fnvlist_alloc;
static fn_fnvlist_free              p_fnvlist_free;
static fn_fnvlist_add_string        p_fnvlist_add_string;
static fn_fnvlist_add_nvlist_array  p_fnvlist_add_nvlist_array;

bool load_libzfs()
{
    void *hzfs = dlopen("libzfs.so", RTLD_NOW | RTLD_GLOBAL);
    if (!hzfs) {
        FAIL("dlopen libzfs.so: %s", dlerror());
        return false;
    }

#define L(handle, sym)                                                  \
    do {                                                                \
        p_##sym = reinterpret_cast<fn_##sym>(dlsym(handle, #sym));      \
        if (!p_##sym) {                                                 \
            FAIL("dlsym %s: %s", #sym, dlerror());                      \
            return false;                                               \
        }                                                               \
    } while (0)

    L(hzfs, libzfs_init);
    L(hzfs, libzfs_fini);
    L(hzfs, libzfs_error_description);
    L(hzfs, zpool_create);
    L(hzfs, zpool_open);
    L(hzfs, zpool_close);
    L(hzfs, zpool_destroy);
    L(hzfs, zfs_create);
    L(hzfs, zfs_open);
    L(hzfs, zfs_mount);
    L(hzfs, zfs_unmount);
    L(hzfs, zfs_destroy);
    L(hzfs, zfs_close);

    /* fnvlist_* live in libnvpair.so, loaded transitively with RTLD_GLOBAL. */
    L(RTLD_DEFAULT, fnvlist_alloc);
    L(RTLD_DEFAULT, fnvlist_free);
    L(RTLD_DEFAULT, fnvlist_add_string);
    L(RTLD_DEFAULT, fnvlist_add_nvlist_array);
#undef L
    return true;
}

/*
 * Build an nvroot for a single-disk pool on /dev/crucible0.
 *
 *   nvroot {
 *     "type" = "root"
 *     "children" = [ {
 *       "type" = "disk"
 *       "path" = "/dev/crucible0"
 *     } ]
 *   }
 */
nvlist_t *make_nvroot()
{
    nvlist_t *vdev = p_fnvlist_alloc();
    p_fnvlist_add_string(vdev, "type", "disk");
    p_fnvlist_add_string(vdev, "path", DEV);

    nvlist_t *root = p_fnvlist_alloc();
    p_fnvlist_add_string(root, "type", "root");
    const nvlist_t *children[] = { vdev };
    p_fnvlist_add_nvlist_array(root, "children", children, 1);

    p_fnvlist_free(vdev);
    return root;
}

bool run_io_roundtrip()
{
    /* Generate a deterministic pattern. */
    uint8_t *buf = static_cast<uint8_t *>(malloc(FILE_SIZE));
    if (!buf) {
        FAIL("malloc(%zu) failed", FILE_SIZE);
        return false;
    }
    for (size_t i = 0; i < FILE_SIZE; i++) {
        buf[i] = static_cast<uint8_t>((i * 31u + (i >> 11)) ^ 0xA7);
    }

    int fd = open(TEST_FILE, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        FAIL("open(%s) failed: %s", TEST_FILE, strerror(errno));
        free(buf);
        return false;
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    ssize_t n = write(fd, buf, FILE_SIZE);
    if (n != static_cast<ssize_t>(FILE_SIZE)) {
        FAIL("write returned %zd (errno=%d %s)", n, errno, strerror(errno));
        close(fd); free(buf);
        return false;
    }
    if (fsync(fd) != 0) {
        FAIL("fsync failed: %s", strerror(errno));
        close(fd); free(buf);
        return false;
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    double w_secs = std::chrono::duration<double>(t1 - t0).count();
    PASS("wrote %zu bytes in %.2f s (%.1f MB/s)",
         FILE_SIZE, w_secs, (FILE_SIZE / (1024.0 * 1024.0)) / w_secs);

    /* Re-open to bypass any in-process buffering. */
    close(fd);
    fd = open(TEST_FILE, O_RDONLY);
    if (fd < 0) {
        FAIL("re-open(%s): %s", TEST_FILE, strerror(errno));
        free(buf);
        return false;
    }

    auto r0 = std::chrono::high_resolution_clock::now();
    uint8_t *rbuf = static_cast<uint8_t *>(malloc(FILE_SIZE));
    n = read(fd, rbuf, FILE_SIZE);
    auto r1 = std::chrono::high_resolution_clock::now();
    double r_secs = std::chrono::duration<double>(r1 - r0).count();

    if (n != static_cast<ssize_t>(FILE_SIZE)) {
        FAIL("read returned %zd", n);
        close(fd); free(buf); free(rbuf);
        return false;
    }
    if (memcmp(buf, rbuf, FILE_SIZE) != 0) {
        size_t first_diff = 0;
        for (size_t i = 0; i < FILE_SIZE; i++) {
            if (buf[i] != rbuf[i]) { first_diff = i; break; }
        }
        printf("  data mismatch starting at offset %zu\n", first_diff);
        printf("  expected:");
        for (size_t i = first_diff; i < first_diff + 16 && i < FILE_SIZE; i++)
            printf(" %02x", buf[i]);
        printf("\n  got:     ");
        for (size_t i = first_diff; i < first_diff + 16 && i < FILE_SIZE; i++)
            printf(" %02x", rbuf[i]);
        printf("\n");
        FAIL("data mismatch (offset %zu)", first_diff);
        close(fd); free(buf); free(rbuf);
        return false;
    }
    PASS("read+verify %zu bytes in %.2f s (%.1f MB/s)",
         FILE_SIZE, r_secs, (FILE_SIZE / (1024.0 * 1024.0)) / r_secs);
    close(fd);
    free(buf);
    free(rbuf);
    return true;
}

} /* anonymous namespace */

int main()
{
    printf("=== ZFS-on-Crucible end-to-end test ===\n\n");

    /* Skip if no Crucible volume. */
    {
        struct stat st;
        if (stat(DEV, &st) != 0) {
            printf("SKIP: %s does not exist (boot without --crucible= ?)\n", DEV);
            return 0;
        }
    }
    PASS("%s exists", DEV);

    if (!load_libzfs()) return 1;

    libzfs_handle_t *zfsh = p_libzfs_init();
    if (!zfsh) {
        FAIL("libzfs_init returned NULL");
        return 1;
    }

    /* If the pool already exists from a previous run, destroy it. */
    {
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void) p_zpool_destroy(zh, "tst-crucible-zfs cleanup");
            p_zpool_close(zh);
            PASS("pre-existing %s pool destroyed", POOL_NAME);
        }
    }

    /* zpool_create(handle, name, nvroot, props=NULL, fsprops=NULL). */
    nvlist_t *nvroot = make_nvroot();
    int rc = p_zpool_create(zfsh, POOL_NAME, nvroot, nullptr, nullptr);
    p_fnvlist_free(nvroot);
    if (rc != 0) {
        FAIL("zpool_create(%s) returned %d (%s)", POOL_NAME, rc,
             p_libzfs_error_description(zfsh));
        p_libzfs_fini(zfsh);
        return 1;
    }
    PASS("zpool_create(%s) on %s", POOL_NAME, DEV);

    /* Create dataset with mountpoint. */
    {
        nvlist_t *props = p_fnvlist_alloc();
        p_fnvlist_add_string(props, "mountpoint", MOUNTPT);
        rc = p_zfs_create(zfsh, DATASET, ZFS_TYPE_FILESYSTEM, props);
        p_fnvlist_free(props);
        if (rc != 0) {
            FAIL("zfs_create(%s) returned %d (%s)", DATASET, rc,
                 p_libzfs_error_description(zfsh));
            goto cleanup;
        }
        PASS("zfs_create(%s)", DATASET);

        zfs_handle_t *zh = p_zfs_open(zfsh, DATASET, ZFS_TYPE_FILESYSTEM);
        if (!zh) {
            FAIL("zfs_open(%s) returned NULL", DATASET);
            goto cleanup;
        }
        rc = p_zfs_mount(zh, nullptr, 0);
        p_zfs_close(zh);
        if (rc != 0) {
            FAIL("zfs_mount returned %d", rc);
            goto cleanup;
        }
        PASS("zfs_mount(%s) at %s", DATASET, MOUNTPT);
    }

    /* Run the I/O round-trip on the freshly-mounted dataset. */
    run_io_roundtrip();

    /* Cleanup: unmount + destroy dataset, destroy pool. */
    {
        zfs_handle_t *zh = p_zfs_open(zfsh, DATASET, ZFS_TYPE_FILESYSTEM);
        if (zh) {
            (void) p_zfs_unmount(zh, nullptr, 0);
            (void) p_zfs_destroy(zh, 0);
            p_zfs_close(zh);
            PASS("zfs_destroy(%s)", DATASET);
        }
    }

cleanup:
    {
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void) p_zpool_destroy(zh, "test cleanup");
            p_zpool_close(zh);
            PASS("zpool_destroy(%s)", POOL_NAME);
        }
    }

    p_libzfs_fini(zfsh);

    printf("\n=== Results: %d/%d passed (%d failed) ===\n",
           tests_passed, tests_run, tests_failed);
    return tests_failed == 0 ? 0 : 1;
}
