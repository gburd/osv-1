#!/usr/bin/env python3
# LEAK #2 FIX (approach 3): per-AS COW-private OVERFLOW region.
#
# The leak: once the global fork arena (fixed 512MiB, monotonic g_bump) exhausts,
# a forked backend's malloc fell through to the IDENTITY kernel heap, which is
# shared verbatim across every AS and NEVER freed by destroy_address_space on
# reap -> ~0.77 MB/backend unreclaimable leak.
#
# The fix: when g_bump exhausts, a child does NOT fall to the identity heap. It
# bumps in its OWN per-AS overflow region -- a COW-private anonymous mapping in a
# dedicated app-slot (slot 97), mapped on demand in the child's address space.
# That region lives in app slots 1..127, so destroy_address_space's normal
# page-table teardown frees it WHOLESALE on reap (exactly like the arena chunks
# and the per-AS free-list). Result: unbounded-churn-safe by construction, zero
# per-object tracking, zero teardown cost, no cross-AS VA reuse (each AS maps its
# own region in its own page tables; identical VAs across AS map to different
# physical pages -- the arena's existing per-AS COW model).
#
# The overflow chunk uses the SAME chunk_header as an arena chunk, so
# fork_arena::free()/usable_size() handle it unchanged; contains() is widened to
# recognize the slot-97 overflow range. Per-chunk free recycles within the AS's
# free-list (in-chunk links stay COW-private/coherent, same as arena chunks).
#
# map_anon() is called OUTSIDE any lock, from app-thread context -- the same
# context the existing large-allocation fallback (mapped_malloc_large) already
# map_anon's from, so it is legal here (preemption on, not IRQ-off).
#
# Env-gated OSV_FORK_ARENA_OVERFLOW (default ON; =0 => old identity-heap fallback
# leak, for the A/B). Idempotent.
import sys
FA="core/fork_arena.cc"
s=open(FA, encoding="utf-8").read()
if "ovf_" in s:
    print("fork_arena.cc already has approach 3"); sys.exit(0)

# 1. includes: map_anon (mmu.hh already included), getenv (cstdlib), atomic ok.
s=s.replace("#include <atomic>\n#include <cstring>\n",
            "#include <atomic>\n#include <cstring>\n#include <cstdlib>\n",1)

# 2. Overflow VA range constant + env gate, after arena_size usage. Put near the
#    g_end declaration.
anchor_gend="uintptr_t g_end = 0;                // arena_base + arena_size\n"
if anchor_gend not in s: print("FATAL g_end anchor"); sys.exit(1)
s=s.replace(anchor_gend, anchor_gend + '''
// LEAK #2 FIX: per-AS overflow lives in a dedicated app slot (97 << 39), clear
// of the arena (96) and the mmap hole. Each child maps its own COW-private
// overflow regions here; identical VAs across AS map to different physical
// pages (per-AS page tables), so there is no cross-AS reuse. contains() treats
// this whole slot as arena-owned so free()/usable_size dispatch overflow chunks.
constexpr uintptr_t ovf_slot_base = 97ull << 39;      // 0x308000000000
constexpr uintptr_t ovf_slot_end  = 98ull << 39;
constexpr size_t    ovf_region_sz = 32ull << 20;      // 32 MiB per mapped region

// OSV_FORK_ARENA_OVERFLOW: 1 (default) => per-AS overflow region (the fix);
//                          0            => old identity-heap fallback (leak) A/B.
int g_ovf_on = -1;
inline bool overflow_on()
{
    int v = g_ovf_on;
    if (v < 0) {
        const char *e = getenv("OSV_FORK_ARENA_OVERFLOW");
        v = (e && e[0] == '0') ? 0 : 1;
        g_ovf_on = v;
    }
    return v != 0;
}
''',1)

# 3. Add overflow fields to as_freelist.
anchor_struct="""struct as_freelist {
    std::atomic<void*>      owner{nullptr};   // address_space* key, null == free slot
    std::atomic<free_node*> heads[num_classes];
};"""
if anchor_struct not in s: print("FATAL as_freelist struct"); sys.exit(1)
s=s.replace(anchor_struct,
"""struct as_freelist {
    std::atomic<void*>      owner{nullptr};   // address_space* key, null == free slot
    std::atomic<free_node*> heads[num_classes];
    // LEAK #2 FIX: per-AS overflow bump region (COW-private, slot 97). When the
    // global arena bump exhausts, this AS bumps here instead of the identity
    // heap. Freed wholesale by destroy_address_space page teardown on reap.
    std::atomic<uintptr_t>  ovf_next{0};      // next byte to carve in current region
    std::atomic<uintptr_t>  ovf_end{0};       // end of current region (0 = none yet)
    spinlock                ovf_lock;         // guards mapping a fresh region (rare)
};""",1)

# 4. contains(): widen to the overflow slot. It is in fork_arena.hh, not .cc.
# handled in the HH patch below.

# 5. alloc(): replace the bump-exhaustion `return nullptr` with the per-AS
#    overflow path. Current code:
old_bump="""    if (!chunk) {
        // Carve a fresh class_size chunk off the bump pointer (atomic).
        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);
        if (c + class_size > g_end) {
            return nullptr;   // arena exhausted
        }
        chunk = reinterpret_cast<void*>(c);
    }"""
if old_bump not in s: print("FATAL alloc bump block"); sys.exit(1)
new_bump="""    if (!chunk) {
        // Carve a fresh class_size chunk off the GLOBAL bump pointer (atomic).
        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);
        if (c + class_size <= g_end) {
            chunk = reinterpret_cast<void*>(c);
        } else if (overflow_on() && fl) {
            // LEAK #2 FIX: global arena exhausted -> bump in THIS AS's private
            // overflow region (slot 97, COW-private, freed on reap). Lock-free
            // bump within the current mapped region; map a fresh region under
            // the per-AS ovf_lock when it runs out.
            chunk = overflow_alloc(fl, class_size);
            if (!chunk) {
                return nullptr;   // could not map overflow: caller uses id-heap
            }
        } else {
            return nullptr;   // arena exhausted (overflow off): identity fallback
        }
    }"""
s=s.replace(old_bump, new_bump,1)

# 6. Add overflow_alloc() helper + a per-AS overflow VA bump. Insert before
#    alloc(). Anchor on "void *alloc(size_t size, size_t alignment)".
anchor_alloc="void *alloc(size_t size, size_t alignment)\n{"
if anchor_alloc not in s: print("FATAL alloc fn anchor"); sys.exit(1)
helper='''// LEAK #2 FIX: allocate a class_size chunk from address space @fl's private
// overflow region. Lock-free bump within the current region; when it is
// exhausted, map a fresh COW-private ovf_region_sz region (slot 97) under the
// per-AS ovf_lock. map_anon runs with no arena lock held and preemption on
// (app-thread context), the same context the large-alloc fallback map_anon's
// from -- so no illegal fault. Each region is mapped in the CURRENT (child) AS,
// so it is COW-private and torn down by destroy_address_space on reap.
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
        // Current region full (or none). Map a fresh COW-private region. We do
        // the map_anon OUTSIDE fl->ovf_lock (map_anon takes the vma-list rwlock
        // and allocates a vma -> nested malloc; holding ovf_lock across that
        // risks a lock-order inversion). Only the publish step is under the lock.
        size_t rsz = ovf_region_sz;
        if (class_size > rsz) {
            rsz = align_up(class_size, ovf_region_sz);   // class_size <= max_alloc (2 MiB)
        }
        // map_anon runs in app-thread context (preemption on) -- the same context
        // the large-alloc fallback map_anon's from -- so it is legal here.
        void *v = mmu::map_anon(reinterpret_cast<void*>(ovf_slot_base), rsz,
                                mmu::mmap_populate, mmu::perm_rw);
        uintptr_t base = reinterpret_cast<uintptr_t>(v);
        if (!v || base < ovf_slot_base || base + rsz > ovf_slot_end) {
            // map failed, or landed outside the overflow slot (contains() would
            // misclassify it). Bail: caller falls back to the identity heap for
            // this one allocation (the old bounded-miss behavior).
            if (v) {
                mmu::munmap(v, rsz);
            }
            return nullptr;
        }
        // Publish the new region under the per-AS lock. If another thread mapped
        // one meanwhile (its region is now current), drop ours and retry the
        // lock-free bump against theirs.
        {
            SCOPE_LOCK(fl->ovf_lock);
            uintptr_t cend = fl->ovf_end.load(std::memory_order_acquire);
            uintptr_t cnext = fl->ovf_next.load(std::memory_order_relaxed);
            if (cend && cnext + class_size <= cend) {
                // someone else's region has room; use it -- discard ours below
            } else {
                // adopt ours: carve the first chunk here, publish the rest
                fl->ovf_next.store(base + class_size, std::memory_order_relaxed);
                fl->ovf_end.store(base + rsz, std::memory_order_release);
                return reinterpret_cast<void*>(base);
            }
        }
        mmu::munmap(v, rsz);   // discard our redundant region, retry the bump
    }
}

'''
s=s.replace(anchor_alloc, helper + anchor_alloc,1)

open(FA,"w").write(s)
print("fork_arena.cc approach 3 applied")

# 7. fork_arena.hh: widen contains() to cover the overflow slot.
HH="include/osv/fork_arena.hh"
h=open(HH, encoding="utf-8").read()
old_contains="""static inline bool contains(const void *p)
{
    auto a = reinterpret_cast<uintptr_t>(p);
    return a >= arena_base && a < arena_base + arena_size;
}"""
if old_contains not in h: print("FATAL contains"); sys.exit(1)
new_contains="""static inline bool contains(const void *p)
{
    auto a = reinterpret_cast<uintptr_t>(p);
    // Arena chunks (slot 96) OR per-AS overflow chunks (slot 97, LEAK #2 FIX).
    // Both use the same chunk_header, so free()/usable_size() dispatch them here.
    return (a >= arena_base && a < arena_base + arena_size) ||
           (a >= (97ull << 39) && a < (98ull << 39));
}"""
h=h.replace(old_contains, new_contains,1)
open(HH,"w").write(h)
print("fork_arena.hh contains widened")
print("APPROACH 3 DONE")
