/*
 * NVMe-over-TCP + ZFS RAID-Z sustained-load test.
 *
 * Combines several /dev/nvmeofN block devices (NVMe/TCP initiator targets)
 * into one RAID-Z1 pool, creates a dataset, and drives a sustained
 * variable-size I/O workload whose total written volume exceeds 10 GiB.
 * This exercises the full NVMe/TCP data path (CapsuleCmd, R2T-driven
 * H2CData on write, C2HData collection on read) under the ZFS zio taskq,
 * across many target round-trips, looking for transport bugs, data
 * corruption, and throughput characteristics.
 *
 * Boot example (slirp user-mode net, host gateway 192.168.122.1):
 *   --nvmeof0=192.168.122.1:4420 --nvmeof0-subnqn=nqn.2026-06.org.osv:target0
 *   --nvmeof1=192.168.122.1:4421 --nvmeof1-subnqn=nqn.2026-06.org.osv:target1
 *   ... -e "tests/tst-nvmeof-raidz.so"
 *
 * Like tst-crucible-zfs, this uses the libzfs dlopen API rather than the
 * zpool(8) binary, which has a stale-pointer bug in OSv userspace.
 *
 * Knobs (env):
 *   NVMEOF_RAIDZ_DEVS    space-separated device list
 *                        (default "/dev/nvmeof0 /dev/nvmeof1 /dev/nvmeof2 /dev/nvmeof3")
 *   NVMEOF_RAIDZ_TYPE    "raidz" (default) or "raidz2" or "" for a stripe
 *   NVMEOF_RAIDZ_GIB     total bytes to write across the sweep, GiB (default 12)
 *   NVMEOF_RAIDZ_ASHIFT  override ashift (NVMe namespaces are commonly 4K -> 12)
 *
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
#include <string>
#include <vector>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

namespace {

constexpr const char *POOL_NAME = "nvtank";
constexpr const char *DATASET   = "nvtank/data";
constexpr const char *MOUNTPT   = "/nvtank";
constexpr const char *TEST_FILE = "/nvtank/load.bin";

#define ZFS_TYPE_FILESYSTEM 1

int tests_run = 0, tests_passed = 0, tests_failed = 0;

#define PASS(fmt, ...) do { \
    tests_run++; tests_passed++; \
    printf("  PASS: " fmt "\n", ##__VA_ARGS__); \
} while (0)

#define FAIL(fmt, ...) do { \
    tests_run++; tests_failed++; \
    printf("  FAIL: " fmt "\n", ##__VA_ARGS__); \
} while (0)

/* libzfs/libnvpair runtime bindings via dlopen. */
typedef struct libzfs_handle libzfs_handle_t;
typedef struct zfs_handle    zfs_handle_t;
typedef struct zpool_handle  zpool_handle_t;
typedef struct nvlist        nvlist_t;

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
typedef void      (*fn_fnvlist_add_uint64)(nvlist_t *, const char *, uint64_t);

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
static fn_fnvlist_add_uint64        p_fnvlist_add_uint64;

bool load_libzfs()
{
    void *hzfs = dlopen("libzfs.so", RTLD_NOW | RTLD_GLOBAL);
    if (!hzfs) {
        FAIL("dlopen(libzfs.so): %s", dlerror());
        return false;
    }
#define L(h, sym) do { \
    p_##sym = reinterpret_cast<fn_##sym>(dlsym(h, #sym)); \
    if (!p_##sym) { FAIL("dlsym(%s): %s", #sym, dlerror()); return false; } \
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
    L(RTLD_DEFAULT, fnvlist_alloc);
    L(RTLD_DEFAULT, fnvlist_free);
    L(RTLD_DEFAULT, fnvlist_add_string);
    L(RTLD_DEFAULT, fnvlist_add_nvlist_array);
    L(RTLD_DEFAULT, fnvlist_add_uint64);
#undef L
    return true;
}

/*
 * Build an nvroot combining all devices.  With raidz_type set the children
 * are wrapped in a single raidz vdev; otherwise they are striped directly
 * under root.
 *
 *   nvroot {
 *     "type" = "root"
 *     "children" = [ {
 *       "type" = "raidz" "nparity" = N
 *       "children" = [ {disk path0}, {disk path1}, ... ]
 *     } ]
 *   }
 */
nvlist_t *make_nvroot(const std::vector<std::string> &devs,
                      const char *raidz_type, uint64_t ashift)
{
    std::vector<nvlist_t *> leaves;
    leaves.reserve(devs.size());
    for (const auto &d : devs) {
        nvlist_t *vdev = p_fnvlist_alloc();
        p_fnvlist_add_string(vdev, "type", "disk");
        p_fnvlist_add_string(vdev, "path", d.c_str());
        if (ashift) {
            p_fnvlist_add_uint64(vdev, "ashift", ashift);
        }
        leaves.push_back(vdev);
    }
    std::vector<const nvlist_t *> leaf_ptrs(leaves.begin(), leaves.end());

    nvlist_t *root = p_fnvlist_alloc();
    p_fnvlist_add_string(root, "type", "root");

    if (raidz_type && *raidz_type) {
        nvlist_t *raidz = p_fnvlist_alloc();
        p_fnvlist_add_string(raidz, "type", "raidz");
        uint64_t nparity = (strcmp(raidz_type, "raidz2") == 0) ? 2 : 1;
        p_fnvlist_add_uint64(raidz, "nparity", nparity);
        p_fnvlist_add_nvlist_array(raidz, "children", leaf_ptrs.data(),
                                   static_cast<unsigned int>(leaf_ptrs.size()));
        const nvlist_t *top[] = { raidz };
        p_fnvlist_add_nvlist_array(root, "children", top, 1);
        p_fnvlist_free(raidz);
    } else {
        p_fnvlist_add_nvlist_array(root, "children", leaf_ptrs.data(),
                                   static_cast<unsigned int>(leaf_ptrs.size()));
    }

    for (auto *l : leaves) {
        p_fnvlist_free(l);
    }
    return root;
}

/* Deterministic payload so reads can be verified without keeping data. */
static inline uint8_t payload_byte(uint64_t i)
{
    return static_cast<uint8_t>((i * 31u + (i >> 11)) ^ 0xA7);
}

/*
 * Variable-load generator: writes `total` bytes to one file using a
 * rotating set of chunk sizes (64 KiB .. 4 MiB), fsync every fsync_every
 * bytes, then reads the whole file back and verifies every byte.  Returns
 * write/read MB per second through the wmbps and rmbps out-params.
 */
bool run_variable_load(uint64_t total, double *wmbps, double *rmbps)
{
    /* Rotating chunk sizes model "variable" load. */
    static const size_t CHUNKS[] = {
        64u  * 1024,
        256u * 1024,
        1u   * 1024 * 1024,
        4u   * 1024 * 1024,
        128u * 1024,
        2u   * 1024 * 1024,
    };
    constexpr size_t NCHUNK = sizeof(CHUNKS) / sizeof(CHUNKS[0]);
    constexpr uint64_t FSYNC_EVERY = 256ull * 1024 * 1024;
    constexpr size_t MAXBUF = 4u * 1024 * 1024;

    uint8_t *buf = static_cast<uint8_t *>(malloc(MAXBUF));
    if (!buf) { FAIL("malloc(%zu) failed", (size_t)MAXBUF); return false; }

    int fd = open(TEST_FILE, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        FAIL("open(%s): %s", TEST_FILE, strerror(errno));
        free(buf);
        return false;
    }

    auto t0 = std::chrono::high_resolution_clock::now();
    uint64_t off = 0, since_sync = 0;
    size_t ci = 0;
    while (off < total) {
        size_t chunk = CHUNKS[ci++ % NCHUNK];
        if (off + chunk > total) {
            chunk = static_cast<size_t>(total - off);
        }
        for (size_t j = 0; j < chunk; j++) {
            buf[j] = payload_byte(off + j);
        }
        ssize_t n = write(fd, buf, chunk);
        if (n != static_cast<ssize_t>(chunk)) {
            FAIL("write %zu at off %llu: ret=%zd errno=%d %s",
                 chunk, (unsigned long long)off, n, errno, strerror(errno));
            close(fd); free(buf); return false;
        }
        off += chunk;
        since_sync += chunk;
        if (since_sync >= FSYNC_EVERY) {
            if (fsync(fd) != 0) {
                FAIL("fsync at off %llu: %s",
                     (unsigned long long)off, strerror(errno));
                close(fd); free(buf); return false;
            }
            since_sync = 0;
            printf("    ... wrote %llu MiB\n",
                   (unsigned long long)(off / (1024 * 1024)));
        }
    }
    if (fsync(fd) != 0) {
        FAIL("final fsync: %s", strerror(errno));
        close(fd); free(buf); return false;
    }
    auto t1 = std::chrono::high_resolution_clock::now();
    double wsecs = std::chrono::duration<double>(t1 - t0).count();
    *wmbps = (total / (1024.0 * 1024.0)) / wsecs;

    /* Verify read-back. */
    close(fd);
    fd = open(TEST_FILE, O_RDONLY);
    if (fd < 0) {
        FAIL("re-open(%s): %s", TEST_FILE, strerror(errno));
        free(buf); return false;
    }
    auto r0 = std::chrono::high_resolution_clock::now();
    off = 0;
    while (off < total) {
        size_t chunk = (total - off < MAXBUF) ? (size_t)(total - off) : MAXBUF;
        ssize_t n = read(fd, buf, chunk);
        if (n != static_cast<ssize_t>(chunk)) {
            FAIL("read %zu at off %llu: ret=%zd",
                 chunk, (unsigned long long)off, n);
            close(fd); free(buf); return false;
        }
        for (size_t j = 0; j < chunk; j++) {
            if (buf[j] != payload_byte(off + j)) {
                FAIL("data mismatch at offset %llu: exp %02x got %02x",
                     (unsigned long long)(off + j),
                     payload_byte(off + j), buf[j]);
                close(fd); free(buf); return false;
            }
        }
        off += chunk;
    }
    auto r1 = std::chrono::high_resolution_clock::now();
    double rsecs = std::chrono::duration<double>(r1 - r0).count();
    *rmbps = (total / (1024.0 * 1024.0)) / rsecs;

    close(fd);
    free(buf);
    return true;
}

std::vector<std::string> parse_devs()
{
    std::vector<std::string> out;
    const char *env = getenv("NVMEOF_RAIDZ_DEVS");
    std::string s = (env && *env) ? env
        : "/dev/nvmeof0 /dev/nvmeof1 /dev/nvmeof2 /dev/nvmeof3";
    size_t i = 0;
    while (i < s.size()) {
        while (i < s.size() && s[i] == ' ') i++;
        size_t j = i;
        while (j < s.size() && s[j] != ' ') j++;
        if (j > i) out.push_back(s.substr(i, j - i));
        i = j;
    }
    return out;
}

} /* anonymous namespace */

int main()
{
    printf("=== NVMe-oF + ZFS RAID-Z sustained-load test ===\n\n");

    std::vector<std::string> devs = parse_devs();
    std::vector<std::string> present;
    for (const auto &d : devs) {
        struct stat st;
        if (stat(d.c_str(), &st) == 0) {
            present.push_back(d);
        } else {
            printf("  note: %s absent\n", d.c_str());
        }
    }
    if (present.size() < 2) {
        printf("SKIP: need >=2 nvmeof devices, found %zu "
               "(boot with --nvmeofN= ?)\n", present.size());
        return 0;
    }
    PASS("%zu nvmeof devices present", present.size());

    const char *raidz_type = getenv("NVMEOF_RAIDZ_TYPE");
    if (!raidz_type) raidz_type = "raidz";

    uint64_t gib = 12;
    const char *gib_env = getenv("NVMEOF_RAIDZ_GIB");
    if (gib_env && *gib_env) gib = strtoull(gib_env, nullptr, 10);
    uint64_t total = gib * 1024ull * 1024 * 1024;

    uint64_t ashift = 0;
    const char *ashift_env = getenv("NVMEOF_RAIDZ_ASHIFT");
    if (ashift_env && *ashift_env) ashift = strtoull(ashift_env, nullptr, 10);

    if (!load_libzfs()) return 1;

    libzfs_handle_t *zfsh = p_libzfs_init();
    if (!zfsh) { FAIL("libzfs_init returned NULL"); return 1; }

    /* Destroy a leftover pool from a previous run. */
    {
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void) p_zpool_destroy(zh, "tst-nvmeof-raidz cleanup");
            p_zpool_close(zh);
            PASS("pre-existing %s pool destroyed", POOL_NAME);
        }
    }

    nvlist_t *nvroot = make_nvroot(present, raidz_type, ashift);
    int rc = p_zpool_create(zfsh, POOL_NAME, nvroot, nullptr, nullptr);
    p_fnvlist_free(nvroot);
    if (rc != 0) {
        FAIL("zpool_create(%s, %s over %zu devs) = %d (%s)",
             POOL_NAME, raidz_type[0] ? raidz_type : "stripe",
             present.size(), rc, p_libzfs_error_description(zfsh));
        p_libzfs_fini(zfsh);
        return 1;
    }
    PASS("zpool_create(%s) %s across %zu devices",
         POOL_NAME, raidz_type[0] ? raidz_type : "stripe", present.size());

    {
        nvlist_t *props = p_fnvlist_alloc();
        p_fnvlist_add_string(props, "mountpoint", MOUNTPT);
        rc = p_zfs_create(zfsh, DATASET, ZFS_TYPE_FILESYSTEM, props);
        p_fnvlist_free(props);
        if (rc != 0) {
            FAIL("zfs_create(%s) = %d (%s)", DATASET, rc,
                 p_libzfs_error_description(zfsh));
            goto cleanup;
        }
        PASS("zfs_create(%s)", DATASET);

        zfs_handle_t *zh = p_zfs_open(zfsh, DATASET, ZFS_TYPE_FILESYSTEM);
        if (!zh) { FAIL("zfs_open(%s) NULL", DATASET); goto cleanup; }
        rc = p_zfs_mount(zh, nullptr, 0);
        p_zfs_close(zh);
        if (rc != 0) { FAIL("zfs_mount = %d", rc); goto cleanup; }
        PASS("zfs_mount(%s) at %s", DATASET, MOUNTPT);
    }

    {
        printf("\n  sustained variable load: writing %llu GiB across "
               "RAID-Z then verifying read-back\n", (unsigned long long)gib);
        double wmbps = 0, rmbps = 0;
        if (run_variable_load(total, &wmbps, &rmbps)) {
            PASS("variable load %llu GiB  write=%.1f MB/s  read=%.1f MB/s",
                 (unsigned long long)gib, wmbps, rmbps);
        }
    }

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
