#!/usr/bin/env python3
# LEAK #2 FIX: global BSS-resident per-size-class VA reclaim free-list for the
# fork arena, so freed chunks are recycled ACROSS address spaces and the global
# bump pointer stops being the only allocation source. Without this, g_bump is
# monotonic (never rewinds), release_as() never returns a dead child's carved
# VA, so after ~700 backends the 512MiB arena VA is exhausted and every forked
# backend's whole heap falls through to the identity kernel heap -- which
# destroy_address_space() never frees on reap -> ~0.77 MB/backend unreclaimable
# leak (measured: .local/leak2/LOCALIZED.md).
#
# WHY A GLOBAL LIST IS SAFE (proven physically, then validated by a data-integrity
# churn test - see .local/leak2/):
#
# The per-AS free-list existed to avoid a REAL corruption: it threaded its `next`
# links THROUGH the COW-private arena chunks, so a free-list HEAD shared across
# address spaces popped a chunk and read its `next` from divergent COW copies ->
# mis-recycle. THIS list stores only the chunk BASE VA (a number) in kernel BSS;
# it NEVER dereferences an arena page to chain the free list, so that specific
# hazard cannot recur.
#
# The deeper safety property is PHYSICAL ISOLATION via per-AS page tables. Every
# address space has its OWN slot-96 page tables. The arena base mapping
# (map_anon mmap_fixed|mmap_populate in AS0) is NEVER munmapped, so VA X always
# resolves; a fresh forked child COW-inherits AS0's populated page for X
# read-only. When ANY address space writes chunk X (the allocator's header write
# happens before any app read), it COW-breaks to its OWN fresh private physical
# page. So the SAME VA in two different address spaces maps to DIFFERENT physical
# pages -- re-issuing a freed VA to another AS cannot alias the freeing AS's
# data. A freed chunk is owned by exactly one popper (per-class spinlock), so it
# is live in at most one AS at a time. (malloc returns uninitialized memory, so
# an app read-before-write is a bug regardless; the allocator itself always
# writes the header first, which COW-breaks.)
#
# Reclaim happens at per-chunk free() time, in the OWNING AS's context (coherent
# header read). It is NOT done at release_as()/destroy_address_space, because
# that runs on the reaper thread in AS0, whose slot-96 view is AS0's pages, not
# the dying child's COW copies -- walking the dying child's list there would read
# the wrong `next` links (the very COW hazard above).
#
# Env-gated OSV_FORK_ARENA_RECLAIM (default ON; =0 => old per-AS-only leaky
# behavior for the A/B). Idempotent.
import sys

F = "core/fork_arena.cc"
with open(F, encoding="utf-8") as f:
    s = f.read()

if "g_reclaim" in s:
    print("fork_arena.cc already has the fix"); sys.exit(0)

# 1) includes: need getenv (cstdlib).
anchor_inc = "#include <atomic>\n#include <cstring>\n"
if anchor_inc not in s:
    print("FATAL: include anchor not found"); sys.exit(1)
s = s.replace(anchor_inc, anchor_inc + "#include <cstdlib>\n", 1)

# 2) Add the global reclaim list state + env gate, right after the g_slot_lock
#    declaration line.
anchor_state = "spinlock g_slot_lock;   // guards slot acquisition only (rare: once per AS)\n"
if anchor_state not in s:
    print("FATAL: g_slot_lock anchor not found"); sys.exit(1)
reclaim_state = anchor_state + '''
// -----------------------------------------------------------------------------
// LEAK #2 FIX: global per-size-class VA reclaim free-list (kernel BSS).
//
// The per-AS free-list above recycles a chunk only within its OWN address
// space; a fresh forked backend starts with an empty per-AS list and must
// bump-carve, and the bump pointer never rewinds, so the 512MiB arena VA is
// permanently consumed after ~700 backends -> exhaustion -> identity-heap
// fallback leak.  This global list captures freed chunks so ANY later address
// space (a fresh forked backend) can reuse them, keeping the arena serving
// indefinitely.  It stores ONLY the chunk base VA (a number) in BSS -- it never
// threads links through COW-private arena pages -- so there is no cross-AS
// coherence hazard (see the file header note on the per-AS design).  A bounded
// ring per class: if full, the freed chunk is simply not reclaimed (its VA
// leaks but is never mis-recycled -- correctness over a full ring).
//
// Gated on OSV_FORK_MEM_REAP (default ON).  =0 restores the old per-AS-only
// behavior for the leak A/B.
constexpr unsigned reclaim_ring_cap = 8192;   // per class; 32 classes -> 256K VAs
struct reclaim_ring {
    spinlock lock;
    unsigned head = 0;   // next push slot
    unsigned count = 0;  // live entries
    uintptr_t va[reclaim_ring_cap];
};
reclaim_ring g_reclaim[num_classes];

// OSV_FORK_ARENA_RECLAIM: 1 (default) => recycle freed chunks globally (the fix);
//                         0            => old per-AS-only free-list (leaky) for A/B.
int g_mem_reap = -1;   // -1 = not yet resolved
inline bool mem_reap_on()
{
    int v = g_mem_reap;
    if (v < 0) {
        const char *e = getenv("OSV_FORK_ARENA_RECLAIM");
        v = (e && e[0] == '0') ? 0 : 1;
        g_mem_reap = v;
    }
    return v != 0;
}

// Pop a reclaimed chunk VA of size-class @idx, or 0 if none.
uintptr_t reclaim_pop(unsigned idx)
{
    reclaim_ring &r = g_reclaim[idx];
    SCOPE_LOCK(r.lock);
    if (r.count == 0) {
        return 0;
    }
    r.head = (r.head + reclaim_ring_cap - 1) % reclaim_ring_cap;   // step back
    uintptr_t v = r.va[r.head];
    r.count--;
    return v;
}

// Push a freed chunk base VA of size-class @idx onto the reclaim ring.  Returns
// false if the ring is full (caller then drops the chunk).
bool reclaim_push(unsigned idx, uintptr_t base)
{
    reclaim_ring &r = g_reclaim[idx];
    SCOPE_LOCK(r.lock);
    if (r.count == reclaim_ring_cap) {
        return false;
    }
    r.va[r.head] = base;
    r.head = (r.head + 1) % reclaim_ring_cap;
    r.count++;
    return true;
}
'''
s = s.replace(anchor_state, reclaim_state, 1)

# 3) alloc(): after the per-AS free-list pop miss and BEFORE the bump carve,
#    consult the global reclaim list (when the fix is on).  The insertion point
#    is the `if (!chunk) {` that guards the bump carve.
anchor_bump = """    if (!chunk) {
        // Carve a fresh class_size chunk off the bump pointer (atomic)."""
if anchor_bump not in s:
    print("FATAL: bump-carve anchor not found"); sys.exit(1)
reclaim_alloc = """    // LEAK #2 FIX: before carving a never-yet-used VA off the monotonic bump
    // pointer, reuse a chunk some (possibly other) address space freed.  This
    // keeps the arena serving fresh forked backends instead of exhausting.
    if (!chunk && mem_reap_on()) {
        uintptr_t v = reclaim_pop(idx);
        if (v) {
            chunk = reinterpret_cast<void*>(v);
        }
    }
    if (!chunk) {
        // Carve a fresh class_size chunk off the bump pointer (atomic)."""
s = s.replace(anchor_bump, reclaim_alloc, 1)

# 4) free(): when the fix is on, push the freed chunk to the GLOBAL reclaim ring
#    (recyclable by any AS) instead of the per-AS Treiber stack.  Keep the per-AS
#    path for the fix-off A/B.  Replace the per-AS push block.
anchor_free = """    as_freelist *fl = slot_for(mmu::current_address_space());
    if (!fl) {
        return;
    }
    // Lock-free Treiber push.  Writing n->next touches the chunk page, which
    // after fork is copy-on-write and COW-private to THIS AS: with no lock held
    // and preemption on, the resulting COW page fault is legal (OSv forbids
    // faulting non-preemptable).
    free_node *head = fl->heads[idx].load(std::memory_order_relaxed);
    do {
        n->next = head;
    } while (!fl->heads[idx].compare_exchange_weak(head, n,
                 std::memory_order_release, std::memory_order_relaxed));"""
if anchor_free not in s:
    print("FATAL: free per-AS-push anchor not found"); sys.exit(1)
reclaim_free = """    if (mem_reap_on()) {
        // LEAK #2 FIX: recycle globally so a fresh forked backend can reuse this
        // chunk (the arena never exhausts).  We store only the base VA in BSS --
        // no link is written into the COW-private chunk page -- so there is no
        // cross-AS coherence hazard.  If the ring is full the chunk is dropped
        // (its VA leaks but is never mis-recycled).  (void)n silences unused.
        (void)n;
        reclaim_push(idx, base);
        return;
    }
    as_freelist *fl = slot_for(mmu::current_address_space());
    if (!fl) {
        return;
    }
    // Lock-free Treiber push.  Writing n->next touches the chunk page, which
    // after fork is copy-on-write and COW-private to THIS AS: with no lock held
    // and preemption on, the resulting COW page fault is legal (OSv forbids
    // faulting non-preemptable).
    free_node *head = fl->heads[idx].load(std::memory_order_relaxed);
    do {
        n->next = head;
    } while (!fl->heads[idx].compare_exchange_weak(head, n,
                 std::memory_order_release, std::memory_order_relaxed));"""
s = s.replace(anchor_free, reclaim_free, 1)

with open(F, "w", encoding="utf-8") as f:
    f.write(s)
print("fork_arena.cc FIX applied OK")
