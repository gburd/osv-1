/*
 * C-only wrapper header for OSv FFI bindings.
 *
 * The actual OSv headers (bio.h, buf.h) include C++ types
 * (waitqueue, boost::intrusive) that bindgen cannot parse.
 * This header re-declares the C-visible API surface needed
 * by the Crucible block device driver.
 */

#ifndef OSV_SYS_WRAPPER_H
#define OSV_SYS_WRAPPER_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

/* --- osv/device.h types (C-compatible) --- */

#define MAXDEVNAME 12

#define D_CHR 0x00000001
#define D_BLK 0x00000002
#define D_REM 0x00000004
#define D_TTY 0x00000010

struct bio;
struct device;
struct uio;
struct disk;

typedef int (*devop_open_t)(struct device *, int);
typedef int (*devop_close_t)(struct device *);
typedef int (*devop_read_t)(struct device *, struct uio *, int);
typedef int (*devop_write_t)(struct device *, struct uio *, int);
typedef int (*devop_ioctl_t)(struct device *, unsigned long, void *);
typedef int (*devop_devctl_t)(struct device *, unsigned long, void *);
typedef void (*devop_strategy_t)(struct bio *);

struct devops {
    devop_open_t open;
    devop_close_t close;
    devop_read_t read;
    devop_write_t write;
    devop_ioctl_t ioctl;
    devop_devctl_t devctl;
    devop_strategy_t strategy;
};

struct driver {
    const char *name;
    struct devops *devops;
    size_t devsz;
    int flags;
};

typedef enum {
    DS_INACTIVE    = 0x00,
    DS_ALIVE       = 0x01,
    DS_ACTIVE      = 0x02,
    DS_DEBUG       = 0x04,
    DS_NOTPRESENT  = 0x08,
    DS_ATTACHING   = 0x10,
    DS_ATTACHED    = 0x20,
} device_state_t;

struct device {
    struct device *next;
    struct driver *driver;
    char name[MAXDEVNAME];
    int flags;
    int active;
    int refcnt;
    off_t size;
    off_t offset;
    size_t max_io_size;
    void *private_data;
    void *softc;
    void *ivars;
    device_state_t state;
    const char *desc;
    int unit;
    int irq;
    int vector;
};

typedef struct device *device_t;

/* --- osv/bio.h types (C-compatible subset) --- */

/* bio_cmd values */
#define BIO_READ   0x01
#define BIO_WRITE  0x02
#define BIO_DELETE 0x04
#define BIO_FLUSH  0x10

/* bio_flags values */
#define BIO_ERROR   0x01
#define BIO_DONE    0x02
#define BIO_ONQUEUE 0x04
#define BIO_ORDERED 0x08

/*
 * daddr_t may already be defined by sys/types.h on some
 * platforms. Guard against redefinition.
 */
#ifndef _DADDR_T_DECLARED
typedef uint64_t daddr_t;
#define _DADDR_T_DECLARED
#endif

/*
 * Opaque bio structure for FFI.
 *
 * The real struct bio contains C++ types (mutex_t, waitqueue)
 * that cannot be represented in C or Rust bindgen. The Rust
 * side treats bio as an opaque pointer obtained from alloc_bio()
 * and accesses fields only through the accessor functions below.
 */

/* --- osv/uio.h types --- */

enum uio_rw { UIO_READ, UIO_WRITE };

struct uio {
    struct iovec *uio_iov;
    int uio_iovcnt;
    off_t uio_offset;
    ssize_t uio_resid;
    enum uio_rw uio_rw;
};

/* --- Function declarations --- */

/* device.h */
struct device *device_create(struct driver *drv,
                             const char *name, int flags);
int device_destroy(struct device *dev);
int device_open(const char *name, int mode, struct device **devp);
int device_close(struct device *dev);
int device_read(struct device *dev, struct uio *uio, int ioflags);
int device_write(struct device *dev, struct uio *uio, int ioflags);
int device_ioctl(struct device *dev, unsigned long cmd, void *arg);
void read_partition_table(struct device *dev);

int enodev(void);
int nullop(void);

/* bio.h */
struct bio *alloc_bio(void);
void destroy_bio(struct bio *bio);
int bio_wait(struct bio *bio);
void biodone(struct bio *bio, bool ok);

/*
 * Bio field accessors.
 *
 * Since struct bio is opaque from the Rust side (it contains
 * C++ members), these functions provide field access. They are
 * implemented in osv_bio_accessors.cc which is compiled as C++
 * with the real OSv headers and linked into the kernel.
 */
uint8_t  osv_bio_get_cmd(const struct bio *b);
void     osv_bio_set_cmd(struct bio *b, uint8_t cmd);
uint8_t  osv_bio_get_flags(const struct bio *b);
void     osv_bio_set_flags(struct bio *b, uint8_t flags);
struct device *osv_bio_get_dev(const struct bio *b);
void     osv_bio_set_dev(struct bio *b, struct device *dev);
off_t    osv_bio_get_offset(const struct bio *b);
void     osv_bio_set_offset(struct bio *b, off_t offset);
size_t   osv_bio_get_bcount(const struct bio *b);
void     osv_bio_set_bcount(struct bio *b, size_t bcount);
void    *osv_bio_get_data(const struct bio *b);
void     osv_bio_set_data(struct bio *b, void *data);
int      osv_bio_get_error(const struct bio *b);
void     osv_bio_set_error(struct bio *b, int error);
void    *osv_bio_get_caller1(const struct bio *b);
void     osv_bio_set_caller1(struct bio *b, void *caller1);
void    *osv_bio_get_private(const struct bio *b);
void     osv_bio_set_private(struct bio *b, void *private_data);
void     osv_bio_set_done(struct bio *b,
                          void (*done_fn)(struct bio *));

/* --- POSIX socket API for network I/O --- */

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

/* --- Kernel logging --- */
int printf(const char *fmt, ...);

#endif /* OSV_SYS_WRAPPER_H */
