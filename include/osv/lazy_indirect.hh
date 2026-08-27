/*
 * Copyright (C) 2013 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef INCLUDED_OSV_INDIRECT_HH
#define INCLUDED_OSV_INDIRECT_HH

#include <atomic>
#if CONF_fork
#include <osv/fork_arena.hh>
#endif

// A lazy_indirect<T> is a small object (8 bytes) which pretends to contain
// an object of arbitrarily-sized type T, while actually allocating one
// dynamically only on first use. This allocation is done in a thread-safe
// manner, even if several threads race to use the object first.
// T should have a default (zero-argument) constructor.
//
// lazy_indirect<T>'s constructor merely zeros the object's 8 bytes, so
// it is ok to cast zeroed memory to lazy_indirect<T> - see an example
// of this use in pthread.cc. However, remember in this case to call
// the lazy_indirect<T>::~lazy_indirect eventually, otherwise the memory used
// to allocate T will leak.

template <typename T>
struct lazy_indirect {
private:
    std::atomic<T*> real;
public:
    lazy_indirect() : real(0) { }
    ~lazy_indirect() { delete real; }
    T *get() {
        T *ret = real.load(std::memory_order_consume);
        if (ret) {
            return ret;
        }
        // Otherwise, we need to allocate the real object. Take care that
        // several threads don't allocate the same object the same time. We
        // use optimistic allocation here, assuming the object is cheap to
        // allocate; Alternatively we could could have also used a mutex.
#if CONF_fork
        // Allocate the backing object on the shared identity kernel heap, not
        // the caller's copy-on-write fork arena.  A lazy_indirect embedded in
        // memory shared across forked processes (e.g. a pthread_cond_t /
        // pthread_mutex_t in a PostgreSQL shared-memory segment) stores this
        // pointer once; every forked backend that uses the same object must be
        // able to dereference it.  If the object lived in one backend's COW
        // arena its virtual address would be unmapped/stale in another backend,
        // so a cross-address-space pthread_cond_signal/wake would fault on the
        // condvar's queue pointers.  The identity heap is mapped verbatim in
        // every fork address space.
        fork_arena::kernel_heap_scope kh;
#endif
        ret = new T;
        T *val = 0;
        if (real.compare_exchange_strong(val, ret,
                std::memory_order_release, std::memory_order_consume)) {
            return ret;
        } else {
            // We lost the race - free the object we allocated.
            delete ret;
            return val; // val == real.load(std::memory_order_consume)
        }
    }
};

#endif /* INCLUDED_OSV_INDIRECT_HH */
