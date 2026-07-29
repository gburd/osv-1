/*
 * Copyright (C) 2013 Cloudius Systems, Ltd.
 *
 * This work is open source software, licensed under the terms of the
 * BSD license as described in the LICENSE file in the top-level directory.
 */

#ifndef INCLUDED_OSV_WAIT_RECORD
#define INCLUDED_OSV_WAIT_RECORD

#include <osv/sched.hh>
#include <osv/kernel_config_fork.h>
#if CONF_fork
#include <osv/aligned_new.hh>
#include <osv/fork_arena.hh>
#endif

// A "waiter" is simple synchronization object, with which one thread calling
// waiter->wait() goes to sleep, and a second thread, which finds this waiter
// on some wait-queue, wakes it up with waiter->wake().
//
// A waiter->wake() is guaranteed to stop or avoid the wait of waiter->wait(),
// no matter which came before which, or even if the two race. And conversely,
// when wake->wait() returns, this can only happen when waker->wake() was
// called, and cannot happen because of a spurious wakeup.
//
// waiter is a single-use object - each of wake() and wait() can only be
// called once on it.
//
// waiter behaves similarly to the familiar "event semaphore" synchronization
// mechanism (e.g., see Event objects in Python and in Microsoft Windows),
// except that waiter is limited to a single waiting thread.

namespace lockfree { struct mutex; }

class waiter {
protected:
    std::atomic<sched::thread*> t CACHELINE_ALIGNED;
public:
    explicit waiter(sched::thread *t) : t(t) { };

    inline void wake() {
        t.load(std::memory_order_relaxed)->wake_with_from_mutex([&] { t.store(nullptr, std::memory_order_release); });
    }

    inline void wait() const {
        sched::thread::wait_until([&] { return !t.load(std::memory_order_acquire); });
    }

    inline void wait(sched::timer* tmr) const {
        sched::thread::wait_until([&] {
            return (tmr && tmr->expired()) || !t.load(std::memory_order_acquire); });
    }

    // The thread() method returns the thread waiting on this waiter, or 0 if
    // the waiter was already woken. It shouldn't normally be used except for
    // sanity assert()s. To help enforce this intended use case, we return a
    // const sched::thread.
    inline const sched::thread *thread(void) const {
        return t.load(std::memory_order_relaxed);
    }

    // woken() returns true if the wait_record was already woken by a wake()
    // (a timeout doesn't set the wait_record to woken()).
    inline bool woken() const {
        return !t.load(std::memory_order_acquire);
    }

    // Signal the wait record as woken without actually waking it up.  Use
    // only with external synchronization.
    void clear() noexcept {
        t.store(nullptr, std::memory_order_release);
    }

    // A waiter object cannot be copied or moved, as wake() on the copy will
    // simply zero its copy of the content - not the original content on which
    // wait() is waiting on.
    waiter(const waiter &) = delete;
    waiter &operator=(const waiter &) = delete;
    waiter(waiter &&) = delete;
    waiter &operator=(waiter &&) = delete;

};

// A "wait_record" is simply a "waiter" (see above) with an added "next"
// pointer, which can be used to enqueue a waiter in wait queue.
// Both mutex and condvar use "wait_record" to hold the waiting thread and
// the wake() operation to wake it. The fact we use the same object for both
// means we can easily move a thread waiting on a condvar to wait on a mutex
// (doing that, a technique called "wait morphing", is intended to reduce
// unnecessary thread wakes).

struct wait_record : public waiter {
    struct wait_record *next;
    explicit wait_record(sched::thread *t) : waiter(t), next(nullptr) { };
    using mutex = lockfree::mutex;
    void wake_lock(mutex* mtx) { t.load(std::memory_order_relaxed)->wake_lock(mtx, this); }
};

#if CONF_fork
static_assert(sizeof(wait_record) <= 128, "per-thread coherent_wr slot too small");
static_assert(alignof(wait_record) <= 64, "per-thread coherent_wr slot underaligned");
// fork() Stage 2 kernel-stack coherence.
//
// OSv has no separate kernel stack: kernel code runs on the app thread stack.
// A wait_record queued on a SHARED kernel mutex/condvar is a LOCAL on the
// waiter's stack.  With per-child COW address spaces, a fork child's stack VA
// maps to a DIFFERENT physical page than the parent sees at that same VA, so a
// parent (running in AS0) that dereferences the child's queued wait_record
// through its own page tables reads the wrong physical page -> owner-assert /
// corruption in mutex::unlock().
//
// Fix (Option A): when the current thread runs in a non-AS0 (fork-child)
// address space, allocate the wait_record from the KERNEL HEAP, which is
// identity-mapped identically in every address space, so its VA is coherent
// cross-AS.  AS0 (default OSv + the parent) keeps the on-stack fast path with
// zero overhead.  Returns true iff the current thread is in a forked child AS.
bool fork_child_needs_heap_wait_record();

// RAII holder giving a wait_record& that lives on the caller's stack for AS0
// threads (fast path, no allocation) or on the kernel heap for fork-child
// threads (AS-coherent).  Frees the heap copy on destruction; the stack copy
// is destroyed by the placement-new'd object's explicit dtor.
class coherent_wait_record {
    alignas(wait_record) char _stack[sizeof(wait_record)];
    wait_record *_wr;
    sched::thread *_slot_owner;
public:
    explicit coherent_wait_record(sched::thread *t) {
        // Cross-AS coherence needs the record in identity memory (not the COW
        // per-AS stack).  Use one of the waiter's OWN preallocated identity
        // slots -- NOT a fresh malloc: allocating here re-enters the memory
        // allocator (this runs under free_page_ranges_lock during page-pool
        // refill) and recursed unboundedly -> kernel-stack overflow (F2b).
        void *slot = fork_child_needs_heap_wait_record()
                         ? t->coherent_wr_take() : nullptr;
        if (slot) {
            _slot_owner = t;
            _wr = new (slot) wait_record(t);
        } else {
            // AS0/no-child fast path, or slots exhausted (deep nesting): the
            // on-stack record allocates nothing.
            _slot_owner = nullptr;
            _wr = new (_stack) wait_record(t);
        }
    }
    ~coherent_wait_record() {
        _wr->~wait_record();
        if (_slot_owner) {
            _slot_owner->coherent_wr_release();
        }
    }
    wait_record &get() { return *_wr; }
    const wait_record &get() const { return *_wr; }
    wait_record *ptr() { return _wr; }
    coherent_wait_record(const coherent_wait_record &) = delete;
    coherent_wait_record &operator=(const coherent_wait_record &) = delete;
};
#endif // CONF_fork

#endif /* INCLUDED_OSV_WAIT_RECORD */
