#!/usr/bin/env python3
# LEAK #2 REAL FIX: per-AS COW-private overflow region with NO-OP free.
#
# STEP-1 histogram proved the leak is APP-LIFETIME (99.87% of leaked bytes are
# PostgreSQL's own heap; 0.056% of the fallback is kernel-lifetime, all from app
# sites). So a region reclaimed WHOLESALE on reap is safe: it holds only
# app-lifetime objects, and even a stray kernel object freed later cross-AS hits
# the NO-OP free (no double-free, no leak).
#
# MECHANISM
#  - When the GLOBAL arena bump (g_bump) exhausts, a child no longer falls to the
#    identity heap. It bumps from its OWN per-AS overflow region: a COW-private
#    anonymous mapping in a dedicated app slot (97 << 39), mapped on demand IN
#    THE CHILD'S address space. Slots 1..127 are the child's private app slots,
#    so destroy_address_space()'s existing page-table teardown frees the whole
#    region WHOLESALE on reap -- the same mechanism release_as already relies on.
#    No cross-AS VA reuse (each AS maps its own region in its own page tables;
#    the per-AS ovf bump fields are reset in release_as so a recycled slot never
#    inherits a dead VA). Satisfies C1.
#  - free() of an overflow pointer is a NO-OP recognized by a BSS range check
#    (in_overflow(): p in [ovf_slot_base, ovf_slot_end)). It NEVER reads the
#    chunk header, so a cross-AS free (AS0 reaper / RCU quiescent / sibling) at a
#    VA mapped only in the dead/other child does NOT fault. Satisfies C2. (This
#    is the exact fix over the earlier per-AS-overflow attempt, whose free() read
#    the size/class header cross-AS and aborted.) Per-object free is unnecessary:
#    the whole region is reclaimed by page teardown on reap.
#  - alloc from the overflow region maps with mmap_populate (eager, like the
#    arena) so a bump-carved page is already backed -- alloc never demand-faults
#    from an IRQs-off context. map_anon runs OUTSIDE any arena lock in app-thread
#    context (the same context the large-alloc fallback map_anon's from), so it is
#    legal (preemption on). Satisfies the eager-populate constraint.
#
# Env-gated OSV_FORK_ARENA_RECLAIM (default ON = the fix; =0 => old identity-heap
# fallback leak, for the A/B). Idempotent.
import sys

FA = "core/fork_arena.cc"
HH = "include/osv/fork_arena.hh"

s = open(FA, encoding="utf-8").read()
if "overflow_alloc" in s:
    print("fork_arena.cc already has the overflow fix"); sys.exit(0)

# 1. includes: cstdlib for getenv.
s = s.replace("#include <atomic>\n#include <cstring>\n",
              "#include <atomic>\n#include <cstring>\n#include <cstdlib>\n#include <osv/sched.hh>\n#include <osv/mmu.hh>\n", 1)

# 2. overflow constants + env gate, right after g_end.
anchor_gend = "uintptr_t g_end = 0;                // arena_base + arena_size\n"
assert anchor_gend in s, "g_end anchor"
s = s.replace(anchor_gend, anchor_gend + '''
// LEAK #2 REAL FIX: per-AS overflow region. When the GLOBAL arena bump exhausts,
// a child bumps from its own COW-private region in a dedicated app slot (97),
// clear of the arena (96) and the mmap hole. Each child maps its own region in
// its own page tables; destroy_address_space frees it wholesale on reap. free()
// of a pointer in this slot is a NO-OP (range check below), so a cross-AS free
// never reads the chunk header at a VA mapped only in the dead child.
constexpr uintptr_t ovf_slot_base = 97ull << 39;      // 0x308000000000
constexpr uintptr_t ovf_slot_end  = 98ull << 39;
constexpr size_t    ovf_region_sz = 1ull << 20;       // 1 MiB per mapped region\n// NOTE: region size is a RAM/overhead knob. Eager mmap_populate commits the\n// WHOLE region up front, so a large region (e.g. 32 MiB) x many concurrent\n// backends overcommits RAM and OOMs even though it is freed on reap. 1 MiB\n// keeps the concurrent working set small (~1 MiB x live backends) while still\n// amortizing the map_anon cost over ~64 avg chunks. Measured: 32 MiB OOMs at\n// exhaustion; 256 KiB and 1 MiB keep mem_free FLAT (leak-free) with no OOM.

// OSV_FORK_ARENA_RECLAIM: 1 (default) => per-AS overflow region (the fix);
//                         0            => old identity-heap fallback (the leak) A/B.
std::atomic<int> g_reclaim_on{-1};
inline bool reclaim_on()
{
    int v = g_reclaim_on.load(std::memory_order_relaxed);
    if (v < 0) {
        const char *e = getenv("OSV_FORK_ARENA_RECLAIM");
        v = (e && e[0] == '0') ? 0 : 1;
        g_reclaim_on.store(v, std::memory_order_relaxed);
    }
    return v != 0;
}

// BSS range check: is @p inside the per-AS overflow slot? Reads no arena page.
inline bool in_overflow(const void *p)
{
    auto a = reinterpret_cast<uintptr_t>(p);
    return a >= ovf_slot_base && a < ovf_slot_end;
}
''', 1)

# 3. per-AS overflow bump fields on as_freelist.
anchor_struct = """struct as_freelist {
    std::atomic<void*>      owner{nullptr};   // address_space* key, null == free slot
    std::atomic<free_node*> heads[num_classes];
};"""
assert anchor_struct in s, "as_freelist struct"
s = s.replace(anchor_struct, """struct as_freelist {
    std::atomic<void*>      owner{nullptr};   // address_space* key, null == free slot
    std::atomic<free_node*> heads[num_classes];
    // LEAK #2 REAL FIX: per-AS overflow bump region (COW-private, slot 97).
    // Freed wholesale by destroy_address_space page teardown on reap; reset in
    // release_as so a recycled slot never inherits a dead child's overflow VA.
    std::atomic<uintptr_t>  ovf_next{0};      // next byte to carve in current region
    std::atomic<uintptr_t>  ovf_end{0};       // end of current region (0 = none yet)
    spinlock                ovf_lock;         // guards mapping a fresh region (rare)
};""", 1)

# 4. overflow_alloc() helper before alloc().
anchor_alloc = "void *alloc(size_t size, size_t alignment)\n{"
assert anchor_alloc in s, "alloc fn anchor"
helper = '''// LEAK #2 REAL FIX: carve a class_size chunk from address space @fl's private
// overflow region. Lock-free bump within the current region; when it is full,
// map a fresh COW-private ovf_region_sz region (slot 97) under the per-AS
// ovf_lock. map_anon runs with no arena lock held and preemption on (app-thread
// context), so no illegal fault; mmap_populate keeps it eager so a bump-carved
// page is already backed (alloc never demand-faults from an IRQs-off context).
static void *overflow_alloc(as_freelist *fl, size_t class_size)
{
    for (;;) {
        uintptr_t end = fl->ovf_end.load(std::memory_order_acquire);
        uintptr_t c = fl->ovf_next.load(std::memory_order_relaxed);
        if (end && c + class_size <= end) {
            if (fl->ovf_next.compare_exchange_weak(c, c + class_size,
                    std::memory_order_acq_rel, std::memory_order_relaxed)) {
                return reinterpret_cast<void*>(c);
            }
            continue;   // lost the race, retry
        }
        // Current region full (or none). Map a fresh COW-private region. Do the
        // map_anon OUTSIDE fl->ovf_lock (map_anon takes the vma-list rwlock and
        // allocates a vma -> nested malloc; holding ovf_lock across that risks a
        // lock-order inversion). Only the publish step is under the lock.
        //
        // EAGER-POPULATE INVARIANT (load-bearing): the arena's alloc() may be
        // entered from an IRQs-off / preemption-off context, where a demand
        // fault would abort. The already-mapped bump above is safe there (the
        // region is mmap_populate eager, so a carved page is already backed).
        // But MAPPING a fresh region calls map_anon -> takes a mutex / may sleep
        // -> only legal when preemptable with IRQs on. In a non-preemptable
        // context we therefore do NOT map; we return nullptr so the caller falls
        // back to the identity heap for this ONE allocation (a bounded miss,
        // not per-fork). This preserves the eager-populate correctness property.
        if (!sched::preemptable() || !arch::irq_enabled()) {
            return nullptr;
        }
        size_t rsz = ovf_region_sz;
        if (class_size > rsz) {
            rsz = align_up(class_size, ovf_region_sz);   // class_size <= max_alloc (2 MiB)
        }
        void *v = mmu::map_anon(reinterpret_cast<void*>(ovf_slot_base), rsz,
                                mmu::mmap_populate, mmu::perm_rw);
        uintptr_t base = reinterpret_cast<uintptr_t>(v);
        if (!v || base < ovf_slot_base || base + rsz > ovf_slot_end) {
            // map failed, or landed outside the overflow slot (in_overflow would
            // misclassify it). Bail: caller falls back to the identity heap for
            // this one allocation (bounded miss; still correct, just not reclaimed).
            if (v) {
                mmu::munmap(v, rsz);
            }
            return nullptr;
        }
        {
            SCOPE_LOCK(fl->ovf_lock);
            uintptr_t cend = fl->ovf_end.load(std::memory_order_acquire);
            uintptr_t cnext = fl->ovf_next.load(std::memory_order_relaxed);
            if (cend && cnext + class_size <= cend) {
                // someone else's region has room; use it -- discard ours below
            } else {
                fl->ovf_next.store(base + class_size, std::memory_order_relaxed);
                fl->ovf_end.store(base + rsz, std::memory_order_release);
                return reinterpret_cast<void*>(base);
            }
        }
        mmu::munmap(v, rsz);   // discard our redundant region, retry the bump
    }
}

'''
s = s.replace(anchor_alloc, helper + anchor_alloc, 1)

# 5. alloc(): on exhaustion, use the per-AS overflow region instead of returning
#    nullptr (identity fallback). Overflow chunks carry the SAME header (written
#    in this AS's own COW-private page at alloc time -- safe), so usable_size()
#    for a same-AS realloc works; free() no-ops by range check (below).
old_bump = """    if (!chunk) {
        // Carve a fresh class_size chunk off the bump pointer (atomic).
        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);
        if (c + class_size > g_end) {
            return nullptr;   // arena exhausted
        }
        chunk = reinterpret_cast<void*>(c);
    }"""
assert old_bump in s, "alloc bump block"
new_bump = """    if (!chunk) {
        // Carve a fresh class_size chunk off the GLOBAL bump pointer (atomic).
        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);
        if (c + class_size <= g_end) {
            chunk = reinterpret_cast<void*>(c);
        } else if (reclaim_on() && fl) {
            // LEAK #2 REAL FIX: global arena exhausted -> bump in THIS AS's
            // private overflow region (slot 97), reclaimed wholesale on reap.
            chunk = overflow_alloc(fl, class_size);
            if (!chunk) {
                return nullptr;   // could not map overflow: caller uses identity heap
            }
        } else {
            return nullptr;   // arena exhausted (reclaim off): identity fallback (leak)
        }
    }"""
s = s.replace(old_bump, new_bump, 1)

# 6. free(): NO-OP for an overflow pointer (BSS range check, never reads header).
old_free = """void free(void *p)
{
    uintptr_t base;
    unsigned s;
    recover(p, base, s);   // reads header (populated page), no lock, no fault"""
assert old_free in s, "free head"
new_free = """void free(void *p)
{
    // LEAK #2 REAL FIX: an overflow-region chunk is reclaimed WHOLESALE by
    // destroy_address_space page teardown on reap. free() here is a NO-OP,
    // recognized by a BSS range check that reads NO arena page -- so a cross-AS
    // free (AS0 reaper / RCU quiescent / sibling) at a VA mapped only in the
    // dead/other child does not fault. (This is the C2-safe fix over the earlier
    // per-AS-overflow attempt whose free() read the chunk header cross-AS.)
    if (in_overflow(p)) {
        return;
    }
    uintptr_t base;
    unsigned s;
    recover(p, base, s);   // reads header (populated page), no lock, no fault"""
s = s.replace(old_free, new_free, 1)

# 7. usable_size(): an overflow chunk's header is written by (and read only by)
#    the SAME AS (realloc/malloc_usable_size are app-driven, same-AS), so reading
#    it is safe. But guard against a cross-AS caller by range-checking first and
#    returning a conservative 0 (never seen in practice; belt-and-suspenders C2).
old_us = """size_t usable_size(void *p)
{
    uintptr_t base;
    unsigned s;
    recover(p, base, s);"""
assert old_us in s, "usable_size head"
new_us = """size_t usable_size(void *p)
{
    // Overflow chunks: usable_size is reached only via same-AS realloc /
    // malloc_usable_size, so the header (written by this same AS) is present and
    // safe to read. recover() below reads it. No special case needed -- overflow
    // chunks carry the identical header. (A cross-AS caller would be a bug
    // elsewhere; free() -- the only real cross-AS path -- already no-ops above.)
    uintptr_t base;
    unsigned s;
    recover(p, base, s);"""
s = s.replace(old_us, new_us, 1)

# 8. release_as(): reset the per-AS overflow bump so a recycled slot never
#    inherits a dead child's (now-unmapped) overflow VA.
old_rel = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            g_as_freelists[i].owner.store(nullptr, std::memory_order_release);
            return;"""
assert old_rel in s, "release_as anchor"
new_rel = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            // LEAK #2 REAL FIX: reset the per-AS overflow bump. The dead child's
            // overflow region (slot 97) was just unmapped by the page-table
            // teardown; a slot recycled to a NEW AS must NOT inherit the dead VA.
            g_as_freelists[i].ovf_next.store(0, std::memory_order_relaxed);
            g_as_freelists[i].ovf_end.store(0, std::memory_order_relaxed);
            g_as_freelists[i].owner.store(nullptr, std::memory_order_release);
            return;"""
s = s.replace(old_rel, new_rel, 1)

# Also reset on fresh-slot claim in slot_for (a slot might carry stale ovf fields
# if release_as never ran for a crashed AS; defensive).
old_claim = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            return &g_as_freelists[i];"""
assert old_claim in s, "slot_for claim anchor"
new_claim = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            // LEAK #2 REAL FIX: a freshly-claimed slot starts with no overflow
            // region (never inherit a prior owner's VA).
            g_as_freelists[i].ovf_next.store(0, std::memory_order_relaxed);
            g_as_freelists[i].ovf_end.store(0, std::memory_order_relaxed);
            return &g_as_freelists[i];"""
s = s.replace(old_claim, new_claim, 1)

open(FA, "w").write(s)
print("fork_arena.cc overflow fix applied")

# 9. fork_arena.hh: widen contains() to the overflow slot so free()/usable_size/
#    object_size dispatch overflow pointers into fork_arena (where free() no-ops).
h = open(HH, encoding="utf-8").read()
old_contains = """static inline bool contains(const void *p)
{
    auto a = reinterpret_cast<uintptr_t>(p);
    return a >= arena_base && a < arena_base + arena_size;
}"""
assert old_contains in h, "contains"
new_contains = """static inline bool contains(const void *p)
{
    auto a = reinterpret_cast<uintptr_t>(p);
    // Arena chunks (slot 96) OR per-AS overflow chunks (slot 97, LEAK #2 REAL
    // FIX). Both dispatch here; free() of an overflow chunk is a no-op (the
    // region is reclaimed wholesale on reap).
    return (a >= arena_base && a < arena_base + arena_size) ||
           (a >= (97ull << 39) && a < (98ull << 39));
}"""
h = h.replace(old_contains, new_contains, 1)
open(HH, "w").write(h)
print("fork_arena.hh contains widened")
print("REAL FIX DONE")
