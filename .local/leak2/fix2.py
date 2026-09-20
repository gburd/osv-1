#!/usr/bin/env python3
# LEAK #2 FIX (SAFE, AS-tied fallback). See FIX-ATTEMPTS.md for why VA-reclaim
# was abandoned. Approach: track each forked child's identity-heap FALLBACK
# allocations (made after the fork arena exhausts) in a fixed BSS hash keyed by
# child address_space*, and free whatever is still live when
# destroy_address_space() reaps that child. g_bump stays monotonic; no VA is
# reissued across the COW boundary. Env-gated OSV_FORK_ARENA_RECLAIM (default ON).
#
# All tracker state is fixed kernel BSS (no allocation in malloc/free). The
# fallback allocation reuses std_malloc's own identity tail: we set a thread-local
# "pending fallback (as)" note before falling through, and track ret at the single
# return point.  Idempotent.
import sys

MEMPOOL = "core/mempool.cc"; MMU = "core/mmu.cc"
HH = "include/osv/fork_arena.hh"; FA = "core/fork_arena.cc"
def rd(p):
    with open(p, encoding="utf-8") as f: return f.read()
def wr(p, s):
    with open(p, "w", encoding="utf-8") as f: f.write(s)

m = rd(MEMPOOL)
if "fb_track" in m:
    print("mempool.cc already has the AS-tied fix"); sys.exit(0)

# 1a. include spinlock.
inc_anchor = "#if CONF_fork\n#include <osv/fork_arena.hh>\n#include <osv/wait_record.hh>\n#endif\n"
if inc_anchor not in m: print("FATAL: include anchor"); sys.exit(1)
m = m.replace(inc_anchor, inc_anchor + "#if CONF_fork\n#include <osv/spinlock.h>\n#endif\n", 1)

# 1b. tracker + reap sweep, after the instrument's probe accessor.
probe_anchor = ('extern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count) {\n'
    "    if (bytes) *bytes = g_app_fallback_bytes.load(std::memory_order_relaxed);\n"
    "    if (count) *count = g_app_fallback_count.load(std::memory_order_relaxed);\n"
    "}\n")
if probe_anchor not in m: print("FATAL: probe accessor anchor (run instrument.py first)"); sys.exit(1)

tracker = probe_anchor + r'''
// ---- LEAK #2 FIX: AS-tied fallback-allocation tracker (fixed BSS) ----------
// Maps an identity-heap FALLBACK pointer -> (child address_space, size). Filled
// only when a child-AS app thread's alloc falls through the exhausted arena to
// the identity heap; drained per-pointer on free(); swept per-AS on reap
// (fork_arena_free_as_fallbacks). No dynamic allocation (entered from inside
// malloc/free); spinlock-guarded; open addressing with linear probing +
// backward-shift delete. 128K slots (~3 MiB BSS). Full-table insert is dropped
// (that one alloc reverts to the old leak). Zero cost before arena exhaustion.
namespace {
#if CONF_fork
struct fb_ent { void *ptr; void *as; size_t size; };
constexpr unsigned fb_track_bits = 17;
constexpr unsigned fb_track_size = 1u << fb_track_bits;
constexpr unsigned fb_track_mask = fb_track_size - 1;
fb_ent  g_fb_track[fb_track_size];
spinlock g_fb_lock;
std::atomic<unsigned long> g_fb_live{0};
// Thread-local note: while set, the current malloc is a child-AS fallback that
// must be tracked once its identity-heap pointer is known (single return point).
__thread void *t_fb_pending_as = nullptr;

inline unsigned fb_hash(void *p) {
    uintptr_t x = reinterpret_cast<uintptr_t>(p) >> 4;
    return (unsigned)((x * 0x9E3779B97F4A7C15ull) >> (64 - fb_track_bits)) & fb_track_mask;
}
void fb_track_insert(void *ptr, void *as, size_t size) {
    SCOPE_LOCK(g_fb_lock);
    unsigned h = fb_hash(ptr);
    for (unsigned i = 0; i < fb_track_size; i++) {
        unsigned s = (h + i) & fb_track_mask;
        if (g_fb_track[s].ptr == nullptr) {
            g_fb_track[s] = { ptr, as, size };
            g_fb_live.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        if (g_fb_track[s].ptr == ptr) { g_fb_track[s] = { ptr, as, size }; return; }
    }
}
bool fb_track_erase(void *ptr) {
    SCOPE_LOCK(g_fb_lock);
    unsigned h = fb_hash(ptr);
    for (unsigned i = 0; i < fb_track_size; i++) {
        unsigned s = (h + i) & fb_track_mask;
        if (g_fb_track[s].ptr == nullptr) return false;
        if (g_fb_track[s].ptr == ptr) {
            g_fb_track[s].ptr = nullptr;
            g_fb_live.fetch_sub(1, std::memory_order_relaxed);
            unsigned j = s;
            for (unsigned k = 1; k < fb_track_size; k++) {
                unsigned t = (s + k) & fb_track_mask;
                if (g_fb_track[t].ptr == nullptr) break;
                unsigned hh = fb_hash(g_fb_track[t].ptr);
                bool movable = (j <= t) ? (hh <= j || hh > t) : (hh <= j && hh > t);
                if (movable) { g_fb_track[j] = g_fb_track[t]; g_fb_track[t].ptr = nullptr; j = t; }
            }
            return true;
        }
    }
    return false;
}
#endif
} // anonymous namespace

#if CONF_fork
// Reaper hook (AS0): free every still-live fallback allocation this child made.
extern "C" void fork_arena_free_as_fallbacks(void *as) {
    if (g_fb_live.load(std::memory_order_relaxed) == 0) return;
    for (;;) {
        void *batch[256]; unsigned n = 0;
        {
            SCOPE_LOCK(g_fb_lock);
            for (unsigned s = 0; s < fb_track_size && n < 256; s++) {
                if (g_fb_track[s].ptr && g_fb_track[s].as == as) {
                    batch[n++] = g_fb_track[s].ptr;
                    g_fb_track[s].ptr = nullptr;
                    g_fb_live.fetch_sub(1, std::memory_order_relaxed);
                }
            }
        }
        if (n == 0) break;
        for (unsigned i = 0; i < n; i++) free(batch[i]);
    }
}
#endif
'''
m = m.replace(probe_anchor, tracker, 1)

# 1c. In std_malloc's fallback path, set the pending-track note (do NOT return;
# let the existing identity tail allocate ret, and track at the single return).
fb_marker = ("        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
             "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
             "        // Arena could not serve it (too large / exhausted): fall through to the")
if fb_marker not in m: print("FATAL: fallback marker (run instrument.py first)"); sys.exit(1)
fb_new = ("        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
          "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
          "        // LEAK #2 FIX: this app-thread alloc fell through to the identity heap.\n"
          "        // If a forked CHILD address space made it, note the AS so we can track\n"
          "        // the resulting pointer at the return and free it on reap. g_bump stays\n"
          "        // monotonic; only the exhaustion fallback is made AS-tied.\n"
          "        if (fork_arena::arena_reclaim_on()) {\n"
          "            mmu::address_space *cas = mmu::current_address_space();\n"
          "            if (cas != mmu::kernel_address_space()) {\n"
          "                t_fb_pending_as = cas;\n"
          "            }\n"
          "        }\n"
          "        // Arena could not serve it (too large / exhausted): fall through to the")
m = m.replace(fb_marker, fb_new, 1)

# 1d. Track ret at the single return of std_malloc. The tail ends with:
tail = "#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n    return ret;\n}"
# only the FIRST such block belongs to std_malloc (calloc etc. differ); std_malloc
# is the first function using it. Replace the first occurrence.
if tail not in m: print("FATAL: std_malloc return tail"); sys.exit(1)
tail_new = ("#if CONF_memory_tracker\n    memory::tracker_remember(ret, size);\n#endif\n"
            "#if CONF_fork\n"
            "    // LEAK #2 FIX: if this malloc was a child-AS arena fallback, track its\n"
            "    // identity-heap pointer so destroy_address_space() frees it on reap.\n"
            "    if (t_fb_pending_as) {\n"
            "        void *as = t_fb_pending_as; t_fb_pending_as = nullptr;\n"
            "        if (ret) fb_track_insert(ret, as, size);\n"
            "    }\n"
            "#endif\n"
            "    return ret;\n}")
m = m.replace(tail, tail_new, 1)

# 1e. free(): drain the tracker for identity-heap frees while non-empty.
free_anchor = "    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }"
if free_anchor not in m: print("FATAL: free identity anchor"); sys.exit(1)
free_new = ("#if CONF_fork\n"
            "    // LEAK #2 FIX: forget a tracked child fallback pointer being freed normally.\n"
            "    // Cheap no-op while the tracker is empty (before the arena ever exhausts).\n"
            "    if (g_fb_live.load(std::memory_order_relaxed) != 0) fb_track_erase(object);\n"
            "#endif\n"
            "    if (!mmu::is_linear_mapped(object, 0)) {\n        return memory::mapped_free_large(object);\n    }")
m = m.replace(free_anchor, free_new, 1)
wr(MEMPOOL, m)
print("mempool.cc AS-tied fix applied OK")

# 2. fork_arena.hh: expose arena_reclaim_on().
h = rd(HH)
if "arena_reclaim_on" not in h:
    hook = "void release_as(void *as);"
    if hook not in h: print("FATAL: fork_arena.hh release_as anchor"); sys.exit(1)
    h = h.replace(hook, hook + "\n\n// LEAK #2 FIX: OSV_FORK_ARENA_RECLAIM env gate (default ON). When on, an app\n// thread's arena-exhausted fallback to the identity heap is made AS-tied so\n// destroy_address_space() frees it on reap. =0 restores the old leak (A/B).\nbool arena_reclaim_on();", 1)
    wr(HH, h); print("fork_arena.hh updated")

# 3. fork_arena.cc: implement arena_reclaim_on().
fa = rd(FA)
if "arena_reclaim_on" not in fa:
    if "#include <cstring>" not in fa: print("FATAL: fork_arena.cc include"); sys.exit(1)
    fa = fa.replace("#include <cstring>", "#include <cstring>\n#include <cstdlib>", 1)
    impl_anchor = "void release_as(void *as)\n{"
    if impl_anchor not in fa: print("FATAL: fork_arena.cc release_as impl"); sys.exit(1)
    impl = ("bool arena_reclaim_on()\n{\n    static int cached = -1;\n    int v = cached;\n"
            "    if (v < 0) {\n        const char *e = getenv(\"OSV_FORK_ARENA_RECLAIM\");\n"
            "        v = (e && e[0] == '0') ? 0 : 1;\n        cached = v;\n    }\n    return v != 0;\n}\n\n")
    fa = fa.replace(impl_anchor, impl + impl_anchor, 1)
    wr(FA, fa); print("fork_arena.cc arena_reclaim_on() added")

# 4. mmu.cc: call the reaper hook in destroy_address_space.
mm = rd(MMU)
if "fork_arena_free_as_fallbacks" not in mm:
    decl_anchor = "std::atomic<int> live_child_address_spaces{0};"
    if decl_anchor not in mm: print("FATAL: mmu.cc lcas anchor"); sys.exit(1)
    mm = mm.replace(decl_anchor, decl_anchor + "\n// LEAK #2 FIX: free a reaped child's still-live identity-heap fallback\n// allocations (core/mempool.cc).\nextern \"C\" void fork_arena_free_as_fallbacks(void *as);", 1)
    ra_anchor = "    fork_arena::release_as(as);\n    delete as;"
    if ra_anchor not in mm: print("FATAL: mmu.cc release_as call anchor"); sys.exit(1)
    mm = mm.replace(ra_anchor,
        "    // LEAK #2 FIX: free this child's still-live identity-heap fallback\n"
        "    // allocations (its per-connection heap PostgreSQL did not free before the\n"
        "    // backend exited) -- otherwise they leak once the arena has exhausted.\n"
        "    fork_arena_free_as_fallbacks(as);\n"
        "    fork_arena::release_as(as);\n    delete as;", 1)
    wr(MMU, mm); print("mmu.cc destroy_address_space hook added")

print("AS-TIED FIX DONE")
