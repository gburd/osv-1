/*
 * Bio field accessors for Rust FFI.
 *
 * struct bio contains C++ members (mutex_t, waitqueue) that
 * cannot be parsed by bindgen. These thin C accessors let the
 * Rust code manipulate bio fields through an opaque pointer.
 *
 * Compiled as C++ (not C) because osv/bio.h includes C++
 * headers (waitqueue.hh, lockfree/mutex.hh). The extern "C"
 * linkage ensures symbols are callable from Rust.
 */

#include <osv/bio.h>

extern "C" {

uint8_t osv_bio_get_cmd(const struct bio *b)
{
    return b->bio_cmd;
}

void osv_bio_set_cmd(struct bio *b, uint8_t cmd)
{
    b->bio_cmd = cmd;
}

uint8_t osv_bio_get_flags(const struct bio *b)
{
    return b->bio_flags;
}

void osv_bio_set_flags(struct bio *b, uint8_t flags)
{
    b->bio_flags = flags;
}

struct device *osv_bio_get_dev(const struct bio *b)
{
    return b->bio_dev;
}

void osv_bio_set_dev(struct bio *b, struct device *dev)
{
    b->bio_dev = dev;
}

off_t osv_bio_get_offset(const struct bio *b)
{
    return b->bio_offset;
}

void osv_bio_set_offset(struct bio *b, off_t offset)
{
    b->bio_offset = offset;
}

size_t osv_bio_get_bcount(const struct bio *b)
{
    return b->bio_bcount;
}

void osv_bio_set_bcount(struct bio *b, size_t bcount)
{
    b->bio_bcount = bcount;
}

void *osv_bio_get_data(const struct bio *b)
{
    return b->bio_data;
}

void osv_bio_set_data(struct bio *b, void *data)
{
    b->bio_data = data;
}

int osv_bio_get_error(const struct bio *b)
{
    return b->bio_error;
}

void osv_bio_set_error(struct bio *b, int error)
{
    b->bio_error = error;
}

void *osv_bio_get_caller1(const struct bio *b)
{
    return b->bio_caller1;
}

void osv_bio_set_caller1(struct bio *b, void *caller1)
{
    b->bio_caller1 = caller1;
}

void *osv_bio_get_private(const struct bio *b)
{
    return b->bio_private;
}

void osv_bio_set_private(struct bio *b, void *private_data)
{
    b->bio_private = private_data;
}

void osv_bio_set_done(struct bio *b, void (*done_fn)(struct bio *))
{
    b->bio_done = done_fn;
}

} /* extern "C" */
