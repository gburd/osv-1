/*
 * Copyright (C) 2013 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#include <assert.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <osv/file.h>
#include <osv/poll.h>
#include <osv/debug.h>
#include <osv/mutex.h>
#include <osv/rcu.hh>
#include <osv/export.h>
#include <boost/range/algorithm/find.hpp>

#include <bsd/sys/sys/queue.h>
#include <osv/kernel_config_fork.h>
#if CONF_fork
#include <osv/sched.hh>
#endif

#include <osv/kernel_config_lazy_stack.h>
#include <osv/kernel_config_lazy_stack_invariant.h>
#include <osv/kernel_config_core_epoll.h>

using namespace osv;

/*
 * The file descriptor table.
 *
 * POSIX makes the descriptor table per-process: fork() gives the child a COPY
 * of it, in which each open fd refers to the SAME open file description (so the
 * offset, status flags and locks are shared and refcounted) while the table
 * ENTRIES are independent -- the child's close(), dup2() and FD_CLOEXEC changes
 * are private, and the child may reuse an fd number the parent still holds.
 *
 * So the slots, the FD_CLOEXEC bits (per-DESCRIPTOR state, unlike the shared
 * f_flags that live on the open file description) and the mutation lock all
 * live in this object, and every accessor below operates on the CURRENT
 * thread's table.
 *
 * Table 0 below is the historic global gfdt[]: it belongs to the kernel and to
 * the initial application, so a build without fork() -- or one that never forks
 * -- resolves every lookup to it and behaves exactly as before.
 */
struct fd_table {
    rcu_ptr<file> fd[FDMAX] = {};
    // FD_CLOEXEC, one bit per descriptor.  A property of the DESCRIPTOR, so it
    // is private to this table: two dup()ed fds, or the same fd in a fork
    // parent and child, can differ here.  (It is emphatically NOT a flag on the
    // open file description, which is shared.)
    uint64_t cloexec[(FDMAX + 63) / 64] = {};
    mutex_t lock = MUTEX_INITIALIZER;
};

/*
 * Table 0: the kernel + initial application's descriptor table.  Statically
 * allocated and never freed; this is what the global gfdt[] was.
 */
static fd_table fdt0;

/*
 * The current thread's descriptor table.
 *
 * This is on the read()/write() path, so it must stay cheap.  Without fork it
 * folds to "&fdt0" and the compiler inlines the whole thing away.  With fork it
 * is ONE pointer load from the current thread (sched::thread::fdtable(), which
 * fork() sets on the child thread and which every thread inherits from its
 * creator) -- deliberately not a map lookup keyed by process identity, which
 * would put a hash lookup in every read() and write().
 */
static inline fd_table *current_fd_table()
{
#if CONF_fork
    auto *t = sched::thread::current();
    if (t) {
        if (fd_table *tbl = t->fdtable()) {
            return tbl;
        }
    }
#endif
    return &fdt0;
}

static inline bool cloexec_get(const fd_table *t, int fd)
{
    return (t->cloexec[fd / 64] >> (fd % 64)) & 1;
}

static inline void cloexec_put(fd_table *t, int fd, bool on)
{
    uint64_t bit = uint64_t(1) << (fd % 64);
    if (on) {
        t->cloexec[fd / 64] |= bit;
    } else {
        t->cloexec[fd / 64] &= ~bit;
    }
}

/*
 * Allocate a file descriptor and assign fd to it atomically.
 *
 * Grabs a reference on fp if successful.
 */
int _fdalloc(struct file *fp, int *newfd, int min_fd)
{
    int fd;
    fd_table *t = current_fd_table();

    fhold(fp);

    for (fd = min_fd; fd < FDMAX; fd++) {
        if (t->fd[fd])
            continue;

        WITH_LOCK(t->lock) {
            /* Now that we hold the lock,
             * make sure the entry is still available */
            if (t->fd[fd].read_by_owner()) {
                continue;
            }

            /* Install */
            t->fd[fd].assign(fp);
            /* A fresh descriptor starts without FD_CLOEXEC (the slot may still
             * carry the flag of a previously closed fd of this number). */
            cloexec_put(t, fd, false);
            *newfd = fd;
        }

        return 0;
    }

    fdrop(fp);
    return EMFILE;
}

extern "C" OSV_LIBC_API
int getdtablesize(void)
{
    return FDMAX;
}

/*
 * Allocate a file descriptor and assign fd to it atomically.
 *
 * Grabs a reference on fp if successful.
 */
int fdalloc(struct file *fp, int *newfd)
{
    return (_fdalloc(fp, newfd, 0));
}

int fdclose(int fd)
{
    struct file* fp;
    fd_table *t = current_fd_table();

    if (fd < 0 || fd >= FDMAX)
        return EBADF;

    WITH_LOCK(t->lock) {

        fp = t->fd[fd].read_by_owner();
        if (fp == nullptr) {
            return EBADF;
        }

        /* Clear only THIS table's entry.  Another table (a fork parent, or a
         * sibling child) that holds the same open file description keeps its own
         * entry and its own reference, so the file survives until the last one
         * goes -- POSIX's "close() in the child does not close the parent's
         * fd".  The descriptor number becomes free in this table alone. */
        t->fd[fd].assign(nullptr);
        cloexec_put(t, fd, false);
    }

    fdrop(fp);

    return 0;
}

/*
 * FD_CLOEXEC accessors.  The flag belongs to the descriptor (this table's slot),
 * not to the open file description, so it is private to the calling process and
 * is not visible through a dup() of the same file into another slot.
 */
bool fd_get_cloexec(int fd)
{
    if (fd < 0 || fd >= FDMAX) {
        return false;
    }
    fd_table *t = current_fd_table();
    WITH_LOCK(t->lock) {
        return cloexec_get(t, fd);
    }
}

void fd_set_cloexec(int fd, bool on)
{
    if (fd < 0 || fd >= FDMAX) {
        return;
    }
    fd_table *t = current_fd_table();
    WITH_LOCK(t->lock) {
        cloexec_put(t, fd, on);
    }
}

#if CONF_fork
/*
 * fork(): give the child a COPY of the caller's descriptor table.
 *
 * Every open fd in the copy refers to the SAME struct file -- the same open file
 * description -- with one extra reference taken for the child.  So the offset,
 * status flags and locks are shared exactly as POSIX requires, and a read() in
 * the child advances the parent's offset.  The FD_CLOEXEC bits are copied too
 * (per-descriptor state, inherited across fork).  Everything after this point is
 * independent: either side may close, dup2 or renumber without the other
 * noticing.
 */
struct fd_table *fork_clone_fd_table(void)
{
    fd_table *child = new fd_table();
    fd_table *parent = current_fd_table();

    WITH_LOCK(parent->lock) {
        for (int fd = 0; fd < FDMAX; fd++) {
            struct file *fp = parent->fd[fd].read_by_owner();
            if (!fp) {
                continue;
            }
            fhold(fp);                  /* the child's own reference */
            child->fd[fd].assign(fp);
        }
        memcpy(child->cloexec, parent->cloexec, sizeof(child->cloexec));
    }
    return child;
}

/*
 * Child teardown: drop this table's reference on every fd still open in it, then
 * free the table.  An open file description the parent (or a sibling child)
 * still holds survives on their references; one that only this child held is
 * genuinely released here, so the peer of a pipe or socket sees EOF/EPIPE just
 * as it would when a real process exits.
 */
void fork_free_fd_table(struct fd_table *tbl)
{
    if (!tbl || tbl == &fdt0) {
        return;
    }
    for (int fd = 0; fd < FDMAX; fd++) {
        struct file *fp = tbl->fd[fd].read_by_owner();
        if (fp) {
            tbl->fd[fd].assign(nullptr);
            fdrop(fp);
        }
    }
    delete tbl;
}

/*
 * execve(): close the descriptors marked FD_CLOEXEC in the current table and
 * keep the rest (POSIX).  This is what makes FD_CLOEXEC mean anything, and it
 * works only because the flag is per-table: a parent that did NOT set
 * FD_CLOEXEC on its own copy of the same open file description is unaffected by
 * the child's exec.
 */
void fork_fd_table_close_on_exec(void)
{
    fd_table *t = current_fd_table();
    for (int fd = 0; fd < FDMAX; fd++) {
        bool close_it;
        WITH_LOCK(t->lock) {
            close_it = cloexec_get(t, fd) && t->fd[fd].read_by_owner();
        }
        if (close_it) {
            fdclose(fd);
        }
    }
}
#endif // CONF_fork

/*
 * Assigns a file pointer to a specific file descriptor.
 * Grabs a reference to the file pointer if successful.
 */
int fdset(int fd, struct file *fp)
{
    struct file *orig;
    fd_table *t = current_fd_table();

    if (fd < 0 || fd >= FDMAX)
        return EBADF;

    fhold(fp);

    WITH_LOCK(t->lock) {
        orig = t->fd[fd].read_by_owner();
        /* Install new file structure in place */
        t->fd[fd].assign(fp);
        /* dup2()/dup3() clear FD_CLOEXEC on the new descriptor (dup3 with
         * O_CLOEXEC sets it afterwards).  Either way it is the NEW descriptor's
         * flag and is never inherited from whatever occupied the slot before. */
        cloexec_put(t, fd, false);
    }

    if (orig)
        fdrop(orig);

    return 0;
}

static bool fhold_if_positive(file* f)
{
    auto c = f->f_count;
    // zero or negative f_count means that the file is being closed; don't
    // increment
    while (c > 0 && !__atomic_compare_exchange_n(&f->f_count, &c, c + 1, true,
            __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
        // nothing to do
    }
    return c > 0;
}

/*
 * Retrieves a file structure from the current thread's descriptor table and
 * increases its refcount in a synchronized way; this ensures that a concurrent
 * close will not interfere.
 */
int fget(int fd, struct file **out_fp)
{
    struct file *fp;

    if (fd < 0 || fd >= FDMAX)
        return EBADF;

#if CONF_lazy_stack_invariant
    assert(sched::preemptable() && arch::irq_enabled());
#endif
#if CONF_lazy_stack
    arch::ensure_next_stack_page();
#endif
    fd_table *t = current_fd_table();
    WITH_LOCK(rcu_read_lock) {
        fp = t->fd[fd].read();
        if (fp == nullptr) {
            return EBADF;
        }

        if (!fhold_if_positive(fp)) {
            return EBADF;
        }
    }

    *out_fp = fp;
    return 0;
}

file::file(unsigned flags, filetype_t type, void *opaque)
    : f_flags(flags)
    , f_count(1)
    , f_data(opaque)
    , f_type(type)
{
}

void file::wake_epoll(int events)
{
#if CONF_core_epoll
    WITH_LOCK(f_lock) {
        if (!f_epolls) {
            return;
        }
        for (auto&& ep : *f_epolls) {
            epoll_wake(ep);
        }
    }
#endif
}

void fhold(struct file* fp)
{
    __sync_fetch_and_add(&fp->f_count, 1);
}

OSV_LIBSOLARIS_API
int fdrop(struct file *fp)
{
    int o = fp->f_count, n;
    bool do_free;
    do {
        n = o - 1;
        if (n == 0) {
            /* We are about to free this file structure, but we still do things with it
             * so set the refcount to INT_MIN, fhold/fdrop may get called again
             * and we don't want to reach this point more than once.
             * INT_MIN is also safe against fget() seeing this file.
             */
            n = INT_MIN;
            do_free = true;
        } else {
            do_free = false;
        }
    } while (!__atomic_compare_exchange_n(&fp->f_count, &o, n, true,
                __ATOMIC_RELAXED, __ATOMIC_RELAXED));

    if (!do_free)
        return 0;

    fp->stop_polls();
    fp->close();
    rcu_dispose(fp);
    return 1;
}

file::~file()
{
}

void file::stop_polls()
{
    auto fp = this;

    poll_drain(fp);
#if CONF_core_epoll
    if (f_epolls) {
        for (auto ep : *f_epolls) {
            epoll_file_closed(ep);
        }
    }
#endif
}

void file::epoll_add(epoll_ptr ep)
{
#if CONF_core_epoll
    WITH_LOCK(f_lock) {
        if (!f_epolls) {
            f_epolls.reset(new std::vector<epoll_ptr>);
        }
        if (boost::range::find(*f_epolls, ep) == f_epolls->end()) {
            f_epolls->push_back(ep);
        }
    }
#endif
}

void file::epoll_del(epoll_ptr ep)
{
#if CONF_core_epoll
    WITH_LOCK(f_lock) {
        assert(f_epolls);
        auto i = boost::range::find(*f_epolls, ep);
        if (i != f_epolls->end()) {
            f_epolls->erase(i);
        }
    }
#endif
}

OSV_LIBSOLARIS_API
dentry* file_dentry(file* fp)
{
    return fp->f_dentry.get();
}

void file_setdata(file* fp, void* data)
{
    fp->f_data = data;
}

bool is_nonblock(struct file *f)
{
    return (f->f_flags & FNONBLOCK);
}

OSV_LIBSOLARIS_API
int file_flags(file *f)
{
    return f->f_flags;
}

OSV_LIBSOLARIS_API
off_t file_offset(file* f)
{
    return f->f_offset;
}

OSV_LIBSOLARIS_API
void file_setoffset(file* f, off_t o)
{
    f->f_offset = o;
}

void* file_data(file* f)
{
    return f->f_data;
}

filetype_t file_type(file* f)
{
    return f->f_type;
}
