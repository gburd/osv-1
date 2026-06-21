/*
 * tst-zfs-dbsim-dev.cc -- device-backed Postgres-WAL ZFS benchmark.
 *
 * A variant of tst-zfs-db-sim that, instead of opening a pre-existing root
 * pool, CREATES a pool on a chosen block device (NVMe-oF or Crucible), runs
 * the db-sim transaction loop in the single C3 configuration (O_DIRECT +
 * primarycache=metadata, the only one that survives at 128 MiB RAM), tears
 * the pool down, and prints one TPS line.
 *
 * The pool can optionally be given a separate log (SLOG/ZIL) vdev so the
 * ZFS intent log -- which carries the synchronous WAL fdatasync traffic --
 * lands on a different backend than the bulk relation data.  This is what
 * lets the workload measure "relation data on Crucible, WAL on NVMe-oF".
 *
 * Knobs (env, passed via OSv --env KEY=VAL inside the -e string):
 *   DBSIM_DATA_DEV   data vdev device path   (e.g. /dev/nvmeof0, /dev/crucible0)
 *   DBSIM_LOG_DEV    optional SLOG log vdev  (empty -> no SLOG)
 *   DBSIM_ASHIFT     vdev ashift             (default 12 = 4K)
 *   DBSIM_DB_MB      database size in MiB    (default 750)
 *   DBSIM_SECONDS    measurement window      (default 30)
 *
 * Boot example (NVMe-oF data, no SLOG):
 *   --nvmeof0=192.168.122.1:4420 --nvmeof0-subnqn=nqn.2026-06.org.osv:target0
 *   -e "--env DBSIM_DATA_DEV=/dev/nvmeof0 tests/tst-zfs-dbsim-dev.so"
 *
 * Boot example (Crucible data + NVMe-oF SLOG):
 *   --crucible0=H:3811,H:3812,H:3813 --crucible0-uuid=... --crucible-block-size=4096
 *   --nvmeof0=192.168.122.1:4420 --nvmeof0-subnqn=nqn.2026-06.org.osv:target0
 *   -e "--env DBSIM_DATA_DEV=/dev/crucible0 --env DBSIM_LOG_DEV=/dev/nvmeof0 \
 *       tests/tst-zfs-dbsim-dev.so"
 *
 * Like tst-crucible-zfs and tst-nvmeof-raidz, this uses the libzfs dlopen
 * API rather than the zpool(8) binary (OSv userspace zpool SIGSEGVs in
 * strlen).  Listed in modules/tests/Makefile.
 *
 * Copyright (C) 2026 OSv Contributors
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dlfcn.h>

/* == tunables (overridable via env in main) ============================== */

static const size_t   PAGE_BYTES        = 8192;   /* ZFS recordsize=8K        */
static const size_t   WAL_RECORD_SIZE   = 80;     /* bytes per WAL entry       */
static const int      WAL_SYNC_INTERVAL = 100;    /* fdatasync every N txns    */

static uint64_t DB_SIZE_MB    = 750;              /* DBSIM_DB_MB               */
static uint64_t DB_PAGES      = (750ULL * 1024 * 1024) / PAGE_BYTES;
static int      BENCH_SECONDS = 30;               /* DBSIM_SECONDS             */

static const char *POOL_NAME = "pgtank";

/* == WAL record layout (80 bytes) ======================================== */

struct __attribute__((packed)) wal_record {
    uint64_t lsn;
    uint64_t xid;
    uint64_t page_idx;
    uint32_t tuple_off;
    uint32_t tuple_len;
    uint8_t  data[48];
};
static_assert(sizeof(wal_record) == WAL_RECORD_SIZE, "WAL record size mismatch");

/* == database page header (matches Postgres HeapPageHeader shape) ======== */

struct __attribute__((packed)) page_header {
    uint64_t pd_lsn;
    uint32_t pd_page_id;
    uint32_t pd_checksum;
    uint16_t pd_lower;
    uint16_t pd_upper;
    uint16_t pd_flags;
    uint16_t pd_reserved;
    uint8_t  pd_data[PAGE_BYTES - 24];
};
static_assert(sizeof(page_header) == PAGE_BYTES, "page_header size mismatch");

/* == libzfs/libnvpair dynamic binding ==================================== */

typedef struct libzfs_handle libzfs_handle_t;
typedef struct zfs_handle    zfs_handle_t;
typedef struct zpool_handle  zpool_handle_t;
typedef struct nvlist        nvlist_t;

#define ZFS_TYPE_FILESYSTEM (1 << 0)

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
typedef int              (*fn_zfs_prop_set)(zfs_handle_t *, const char *,
                                            const char *);
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
static fn_zfs_prop_set              p_zfs_prop_set;
static fn_zfs_destroy               p_zfs_destroy;
static fn_zfs_close                 p_zfs_close;
static fn_fnvlist_alloc             p_fnvlist_alloc;
static fn_fnvlist_free              p_fnvlist_free;
static fn_fnvlist_add_string        p_fnvlist_add_string;
static fn_fnvlist_add_nvlist_array  p_fnvlist_add_nvlist_array;
static fn_fnvlist_add_uint64        p_fnvlist_add_uint64;

static bool load_libzfs(void)
{
    void *h = dlopen("libzfs.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "SKIP: cannot load libzfs.so: %s\n", dlerror()); return false; }
#define L(handle, sym) \
    p_##sym = (fn_##sym)dlsym(handle, #sym); \
    if (!p_##sym) { fprintf(stderr, "SKIP: symbol " #sym " not found\n"); return false; }
    L(h, libzfs_init) L(h, libzfs_fini) L(h, libzfs_error_description)
    L(h, zpool_create) L(h, zpool_open) L(h, zpool_close) L(h, zpool_destroy)
    L(h, zfs_create) L(h, zfs_open) L(h, zfs_prop_set) L(h, zfs_destroy) L(h, zfs_close)
    L(RTLD_DEFAULT, fnvlist_alloc) L(RTLD_DEFAULT, fnvlist_free)
    L(RTLD_DEFAULT, fnvlist_add_string) L(RTLD_DEFAULT, fnvlist_add_nvlist_array)
    L(RTLD_DEFAULT, fnvlist_add_uint64)
#undef L
    return true;
}

/*
 * Build an nvroot with one data disk and an optional log (SLOG) disk.
 *
 *   nvroot {
 *     "type" = "root"
 *     "children" = [
 *       { "type"="disk" "path"=data_dev "ashift"=N },
 *       { "type"="disk" "path"=log_dev  "ashift"=N
 *         "is_log"=1 "alloc_bias"="log" }   // only if log_dev set
 *     ]
 *   }
 *
 * The is_log + alloc_bias="log" pair is how OpenZFS marks a top-level child
 * as a separate intent-log vdev (see cmd/zpool/zpool_vdev.c and
 * include/sys/fs/zfs.h ZPOOL_CONFIG_IS_LOG / ALLOCATION_BIAS).
 */
static nvlist_t *make_nvroot(const char *data_dev, const char *log_dev,
                             uint64_t ashift)
{
    nvlist_t *data_vdev = p_fnvlist_alloc();
    p_fnvlist_add_string(data_vdev, "type", "disk");
    p_fnvlist_add_string(data_vdev, "path", data_dev);
    if (ashift) p_fnvlist_add_uint64(data_vdev, "ashift", ashift);

    nvlist_t *log_vdev = nullptr;
    if (log_dev && *log_dev) {
        log_vdev = p_fnvlist_alloc();
        p_fnvlist_add_string(log_vdev, "type", "disk");
        p_fnvlist_add_string(log_vdev, "path", log_dev);
        if (ashift) p_fnvlist_add_uint64(log_vdev, "ashift", ashift);
        p_fnvlist_add_uint64(log_vdev, "is_log", 1);
        p_fnvlist_add_string(log_vdev, "alloc_bias", "log");
    }

    nvlist_t *root = p_fnvlist_alloc();
    p_fnvlist_add_string(root, "type", "root");
    if (log_vdev) {
        const nvlist_t *children[] = { data_vdev, log_vdev };
        p_fnvlist_add_nvlist_array(root, "children", children, 2);
    } else {
        const nvlist_t *children[] = { data_vdev };
        p_fnvlist_add_nvlist_array(root, "children", children, 1);
    }

    p_fnvlist_free(data_vdev);
    if (log_vdev) p_fnvlist_free(log_vdev);
    return root;
}

/* == dataset management (C3 config) ====================================== */

static int setup_dataset(libzfs_handle_t *zfsh, const char *ds_name,
                         const char *mountpoint)
{
    umount2("/scratch", MNT_DETACH);
    zfs_handle_t *old = p_zfs_open(zfsh, ds_name, ZFS_TYPE_FILESYSTEM);
    if (old) {
        p_zfs_destroy(old, 0);
        p_zfs_close(old);
    }

    int rc = p_zfs_create(zfsh, ds_name, ZFS_TYPE_FILESYSTEM, nullptr);
    if (rc != 0) {
        fprintf(stderr, "  zfs_create(%s) failed: %d\n", ds_name, rc);
        return rc;
    }
    zfs_handle_t *zh = p_zfs_open(zfsh, ds_name, ZFS_TYPE_FILESYSTEM);
    if (!zh) { fprintf(stderr, "  zfs_open(%s) failed\n", ds_name); return -1; }

    /* C3: O_DIRECT + primarycache=metadata, compression off, logbias=latency.
     * logbias=latency routes sync writes through the ZIL -> the SLOG, which
     * is exactly what the split config measures. */
    p_zfs_prop_set(zh, "recordsize",   "8K");
    p_zfs_prop_set(zh, "dedup",        "off");
    p_zfs_prop_set(zh, "compression",  "off");
    p_zfs_prop_set(zh, "primarycache", "metadata");
    p_zfs_prop_set(zh, "logbias",      "latency");
    p_zfs_prop_set(zh, "mountpoint",   mountpoint);
    p_zfs_close(zh);
    return 0;
}

static void destroy_dataset(libzfs_handle_t *zfsh, const char *ds_name)
{
    umount2("/scratch", MNT_DETACH);
    zfs_handle_t *zh = p_zfs_open(zfsh, ds_name, ZFS_TYPE_FILESYSTEM);
    if (zh) {
        p_zfs_destroy(zh, 0);
        p_zfs_close(zh);
    }
}

/* == helpers ============================================================= */

static uint64_t xorshift64(uint64_t &s)
{
    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
    return s;
}

static uint32_t simple_checksum(const uint8_t *data, size_t len)
{
    uint32_t c = 0;
    for (size_t i = 0; i < len; i++) c = (c << 1) ^ data[i];
    return c;
}

struct bench_result {
    uint64_t txns;
    uint64_t wal_syncs;
    double   elapsed_s;
    bool     io_error;
    char     error_msg[64];
};

static bool init_database(int db_fd)
{
    off_t db_size = (off_t)(DB_PAGES * PAGE_BYTES);
    if (ftruncate(db_fd, db_size) != 0) {
        fprintf(stderr, "  ERROR: ftruncate failed: %s\n", strerror(errno));
        return false;
    }
    return true;
}

static bench_result run_benchmark(int db_fd, int wal_fd, page_header *page_buf)
{
    using clock = std::chrono::steady_clock;

    static wal_record wal_rec;

    uint64_t rng     = 0xDEADBEEFCAFEBABEULL;
    uint64_t lsn     = 1;
    uint64_t txns    = 0;
    uint64_t wal_syn = 0;

    bench_result res = {};
    res.io_error     = false;

    auto t_start = clock::now();
    auto t_end   = t_start + std::chrono::seconds(BENCH_SECONDS);

    while (clock::now() < t_end) {
        for (int b = 0; b < 64; b++) {
            uint64_t page_idx = xorshift64(rng) % DB_PAGES;
            off_t    page_off = (off_t)(page_idx * PAGE_BYTES);

            ssize_t n = pread(db_fd, page_buf, PAGE_BYTES, page_off);
            if (n != (ssize_t)PAGE_BYTES) {
                memset(page_buf, 0, PAGE_BYTES);
                page_buf->pd_page_id = (uint32_t)page_idx;
                page_buf->pd_lower   = 32;
                page_buf->pd_upper   = (uint16_t)PAGE_BYTES;
            }

            uint32_t tuple_off = (uint32_t)(xorshift64(rng) %
                                            (sizeof(page_buf->pd_data) - 8));
            uint8_t *tuple_ptr = page_buf->pd_data + tuple_off;
            uint64_t new_val   = xorshift64(rng);
            memcpy(tuple_ptr, &new_val, 8);
            page_buf->pd_lsn      = lsn;
            page_buf->pd_checksum = simple_checksum(
                (const uint8_t *)page_buf, PAGE_BYTES - 4);

            wal_rec.lsn       = lsn;
            wal_rec.xid       = txns + 1;
            wal_rec.page_idx  = page_idx;
            wal_rec.tuple_off = tuple_off;
            wal_rec.tuple_len = 8;
            memcpy(wal_rec.data, tuple_ptr, 8);
            n = write(wal_fd, &wal_rec, WAL_RECORD_SIZE);
            if (n != (ssize_t)WAL_RECORD_SIZE) {
                res.io_error = true;
                snprintf(res.error_msg, sizeof(res.error_msg),
                         "WAL write: %s", strerror(errno));
                goto done;
            }

            n = pwrite(db_fd, page_buf, PAGE_BYTES, page_off);
            if (n != (ssize_t)PAGE_BYTES) {
                res.io_error = true;
                snprintf(res.error_msg, sizeof(res.error_msg),
                         "pwrite: %s", strerror(errno));
                goto done;
            }

            if ((++txns % WAL_SYNC_INTERVAL) == 0) {
                fdatasync(wal_fd);
                wal_syn++;
            }
            lsn++;
        }
    }

done:;
    res.elapsed_s = std::chrono::duration<double>(clock::now() - t_start).count();
    res.txns      = txns;
    res.wal_syncs = wal_syn;
    return res;
}

/* == main ================================================================ */

int main(void)
{
    const char *data_dev = getenv("DBSIM_DATA_DEV");
    const char *log_dev  = getenv("DBSIM_LOG_DEV");
    const char *ashift_s = getenv("DBSIM_ASHIFT");
    const char *db_mb_s  = getenv("DBSIM_DB_MB");
    const char *secs_s   = getenv("DBSIM_SECONDS");

    if (!data_dev || !*data_dev) {
        fprintf(stderr, "SKIP: DBSIM_DATA_DEV not set\n");
        return 1;
    }
    uint64_t ashift = ashift_s && *ashift_s ? strtoull(ashift_s, nullptr, 10) : 12;
    if (db_mb_s && *db_mb_s) DB_SIZE_MB = strtoull(db_mb_s, nullptr, 10);
    if (secs_s && *secs_s)   BENCH_SECONDS = (int)strtol(secs_s, nullptr, 10);
    DB_PAGES = (DB_SIZE_MB * 1024ULL * 1024ULL) / PAGE_BYTES;
    bool have_log = log_dev && *log_dev;

    printf("=== device-backed ZFS db-sim: %llu MiB DB, %d s window ===\n",
           (unsigned long long)DB_SIZE_MB, BENCH_SECONDS);
    printf("    data=%s  log=%s  ashift=%llu  pool=%s\n",
           data_dev, have_log ? log_dev : "none",
           (unsigned long long)ashift, POOL_NAME);
    printf("    config C3: O_DIRECT + primarycache=metadata + logbias=latency\n\n");

    /* Devices must exist (boot without --nvmeofN/--crucibleN leaves them out). */
    {
        struct stat st;
        if (stat(data_dev, &st) != 0) {
            printf("SKIP: data device %s does not exist\n", data_dev);
            return 1;
        }
        if (have_log && stat(log_dev, &st) != 0) {
            printf("SKIP: log device %s does not exist\n", log_dev);
            return 1;
        }
    }

    if (!load_libzfs()) return 1;

    libzfs_handle_t *zfsh = p_libzfs_init();
    if (!zfsh) { fprintf(stderr, "libzfs_init failed\n"); return 1; }

    /* Destroy a leftover pool from a previous run. */
    {
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void)p_zpool_destroy(zh, "tst-zfs-dbsim-dev cleanup");
            p_zpool_close(zh);
            printf("pre-existing %s pool destroyed\n", POOL_NAME);
        }
    }

    nvlist_t *nvroot = make_nvroot(data_dev, log_dev, ashift);
    int rc = p_zpool_create(zfsh, POOL_NAME, nvroot, nullptr, nullptr);
    p_fnvlist_free(nvroot);
    if (rc != 0) {
        fprintf(stderr, "zpool_create(%s) failed: %d (%s)\n", POOL_NAME, rc,
                p_libzfs_error_description(zfsh));
        p_libzfs_fini(zfsh);
        return 1;
    }
    printf("zpool_create(%s) ok\n", POOL_NAME);

    uint64_t phys_ram_mb = ((uint64_t)sysconf(_SC_PHYS_PAGES) *
                            (uint64_t)sysconf(_SC_PAGE_SIZE)) >> 20;
    printf("Physical RAM detected: %llu MiB\n\n",
           (unsigned long long)phys_ram_mb);

    page_header *page_buf = nullptr;
    if (posix_memalign((void **)&page_buf, PAGE_BYTES, PAGE_BYTES) != 0) {
        fprintf(stderr, "posix_memalign failed: %s\n", strerror(errno));
        goto destroy_pool;
    }

    {
        char ds_name[256];
        snprintf(ds_name, sizeof(ds_name), "%s/scratch", POOL_NAME);

        bench_result res = {};
        res.io_error = true;
        snprintf(res.error_msg, sizeof(res.error_msg), "setup failed");

        if (setup_dataset(zfsh, ds_name, "/scratch") == 0) {
            mkdir("/scratch",       0755);
            mkdir("/scratch/dbsim", 0755);

            const char *db_path  = "/scratch/dbsim/data.db";
            const char *wal_path = "/scratch/dbsim/wal.log";

            int db_fd = open(db_path, O_RDWR | O_CREAT | O_TRUNC | O_DIRECT, 0644);
            int wal_fd = -1;
            if (db_fd < 0) {
                fprintf(stderr, "  open(data.db) failed: %s\n", strerror(errno));
                snprintf(res.error_msg, sizeof(res.error_msg),
                         "open db: %s", strerror(errno));
            } else {
                wal_fd = open(wal_path,
                              O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
                if (wal_fd < 0) {
                    fprintf(stderr, "  open(wal.log) failed: %s\n", strerror(errno));
                    snprintf(res.error_msg, sizeof(res.error_msg),
                             "open wal: %s", strerror(errno));
                    close(db_fd);
                    db_fd = -1;
                }
            }

            if (db_fd >= 0 && wal_fd >= 0) {
                if (init_database(db_fd)) {
                    res = run_benchmark(db_fd, wal_fd, page_buf);
                }
                close(db_fd);
                close(wal_fd);
                unlink(db_path);
                unlink(wal_path);
                rmdir("/scratch/dbsim");
            }
            destroy_dataset(zfsh, ds_name);
        }

        double tps = res.elapsed_s > 0.0 ? (double)res.txns / res.elapsed_s : 0.0;
        printf("\n");
        if (res.io_error) {
            printf("RESULT: FAILED [%s]\n", res.error_msg);
        } else {
            printf("RESULT: PASS  %.1f txn/s\n", tps);
        }
        printf("TPS=%.1f txns=%llu elapsed=%.1f wal_syncs=%llu "
               "io_error=%s data=%s log=%s\n",
               tps, (unsigned long long)res.txns, res.elapsed_s,
               (unsigned long long)res.wal_syncs,
               res.io_error ? "true" : "false",
               data_dev, have_log ? log_dev : "none");
        fflush(stdout);

        free(page_buf);

        bool ok = !res.io_error;
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void)p_zpool_destroy(zh, "tst-zfs-dbsim-dev teardown");
            p_zpool_close(zh);
        }
        p_libzfs_fini(zfsh);
        return ok ? 0 : 1;
    }

destroy_pool:
    {
        zpool_handle_t *zh = p_zpool_open(zfsh, POOL_NAME);
        if (zh) {
            (void)p_zpool_destroy(zh, "tst-zfs-dbsim-dev teardown");
            p_zpool_close(zh);
        }
    }
    p_libzfs_fini(zfsh);
    return 1;
}
