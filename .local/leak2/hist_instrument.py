#!/usr/bin/env python3
# LEAK #2 STEP 1: app-vs-kernel-lifetime HISTOGRAM of the identity-heap fallback.
#
# The leak = app-thread allocations that fall THROUGH the exhausted fork arena to
# the identity kernel heap (VA >= 0x400000000000), which destroy_address_space()
# never frees on reap. The decisive unknown for the fix: of those leaked bytes,
# how much is (a) the backend's own APP heap -- freed by the SAME AS before exit
# or simply orphaned at reap = app-lifetime, SAFE to reclaim wholesale -- vs
# (b) KERNEL objects (vnode/dentry/file or their nested members) freed LATER by a
# CROSS-AS path (AS0 reaper / RCU quiescent thread / sibling) = kernel-lifetime,
# UNSAFE to wholesale-free (the UAF that crashed the reap-tracker).
#
# This instrument answers it by TAGGING every fallback allocation with its caller
# PC + allocating AS, and at FREE time classifying by WHO frees it:
#   * freed by the same AS (an app thread of the backend, before reap)  -> APP-lifetime
#   * freed cross-AS (a different current_address_space at free time)    -> KERNEL-lifetime
#   * never freed by the time release_as(alloc_as) runs                  -> LEAKED-at-reap
# Bytes are bucketed per caller-PC into a fixed BSS histogram (coherent cross-AS,
# read-only at free time -- NEVER touches the possibly-unmapped chunk page, so no
# cross-AS fault; that was the hard-won invariant).
#
# Purely measurement. Stripped from the final fix. Idempotent.
import sys

MEMPOOL = "core/mempool.cc"
MMU     = "core/mmu.cc"
LEAKPROBE = "core/leak_probe.cc"

def read(p):
    with open(p, encoding="utf-8") as f: return f.read()
def write(p, s):
    with open(p, "w", encoding="utf-8") as f: f.write(s)

# ---------------------------------------------------------------------------
# 1. mempool.cc: the histogram engine + tag on fallback + classify on free.
# ---------------------------------------------------------------------------
m = read(MEMPOOL)
if "fbhist_" in m:
    print("mempool.cc already has histogram")
else:
    anchor = "#if CONF_fork\n#include <osv/fork_arena.hh>\n#include <osv/wait_record.hh>\n#endif\n"
    if anchor not in m:
        print("FATAL: mempool include anchor not found"); sys.exit(1)

    engine = anchor + r"""
#if CONF_fork
// ===========================================================================
// LEAK #2 STEP 1 HISTOGRAM (OSV_LEAK_PROBE): app-vs-kernel-lifetime of the
// identity-heap fallback. All state is kernel BSS (coherent in every AS); the
// free-time classification reads only BSS + current_address_space(), NEVER the
// chunk page, so it cannot fault cross-AS.
// ===========================================================================
#include <atomic>
#include <osv/mmu.hh>

namespace fbhist {

// --- cumulative fallback totals (the LOCALIZED.md fb_bytes/fb_count) ---
std::atomic<unsigned long> g_fb_bytes{0};
std::atomic<unsigned long> g_fb_count{0};

// --- per-allocation tag table: records every LIVE identity-fallback chunk so
//     free()/release_as can classify it. Open-addressed, power-of-two, BSS. ---
struct tag {
    std::atomic<uintptr_t> va{0};    // user pointer, 0 == empty slot
    unsigned long          size{0};
    uintptr_t              caller{0};// return address that requested it
    void*                  alloc_as{nullptr};
};
constexpr unsigned TAG_BITS = 18;            // 256K slots; leaked tags are
                                             // swept + cleared on reap so the
                                             // table does not saturate.
constexpr unsigned TAG_N    = 1u << TAG_BITS;
constexpr unsigned TAG_MASK = TAG_N - 1;
tag g_tags[TAG_N];
std::atomic<unsigned long> g_tag_live{0};
std::atomic<unsigned long> g_tag_full_drops{0};

inline unsigned hash_va(uintptr_t v) {
    v ^= v >> 33; v *= 0xff51afd7ed558ccdULL; v ^= v >> 29;
    return (unsigned)(v & TAG_MASK);
}
constexpr uintptr_t TAG_TOMB = 1;   // deleted-slot sentinel (probe continues past it)

// --- per-caller-PC site histogram. Small fixed table keyed by PC. ---
struct site {
    std::atomic<uintptr_t>     pc{0};        // 0 == empty
    std::atomic<unsigned long> fb_bytes{0};  // total fallback bytes from this PC
    std::atomic<unsigned long> fb_count{0};
    std::atomic<unsigned long> freed_app_bytes{0};    // freed by SAME AS (app-lifetime)
    std::atomic<unsigned long> freed_app_count{0};
    std::atomic<unsigned long> freed_kern_bytes{0};   // freed CROSS-AS (kernel-lifetime)
    std::atomic<unsigned long> freed_kern_count{0};
    std::atomic<unsigned long> leaked_bytes{0};       // still live at release_as(alloc_as)
    std::atomic<unsigned long> leaked_count{0};
};
constexpr unsigned SITE_N = 512;
site g_sites[SITE_N];

site* site_for(uintptr_t pc) {
    unsigned h = hash_va(pc) % SITE_N;
    for (unsigned i = 0; i < SITE_N; i++) {
        unsigned s = (h + i) % SITE_N;
        uintptr_t cur = g_sites[s].pc.load(std::memory_order_acquire);
        if (cur == pc) return &g_sites[s];
        if (cur == 0) {
            uintptr_t expect = 0;
            if (g_sites[s].pc.compare_exchange_strong(expect, pc,
                    std::memory_order_acq_rel)) return &g_sites[s];
            if (g_sites[s].pc.load(std::memory_order_acquire) == pc) return &g_sites[s];
        }
    }
    return &g_sites[h];   // table full: fold into the home slot (rare)
}

// Record a fallback allocation. Called from std_malloc's identity-fallback path.
inline void on_fallback(void *p, unsigned long size, uintptr_t caller) {
    g_fb_bytes.fetch_add(size, std::memory_order_relaxed);
    g_fb_count.fetch_add(1, std::memory_order_relaxed);
    site *st = site_for(caller);
    st->fb_bytes.fetch_add(size, std::memory_order_relaxed);
    st->fb_count.fetch_add(1, std::memory_order_relaxed);
    // insert into the tag table (linear probe from hash home)
    uintptr_t va = reinterpret_cast<uintptr_t>(p);
    unsigned h = hash_va(va);
    constexpr unsigned INS_MAX = 256;   // bounded insert probe (drop if full)
    for (unsigned i = 0; i < INS_MAX; i++) {
        unsigned s = (h + i) & TAG_MASK;
        uintptr_t expect = 0;
        // Claim an empty (0) slot within the bounded window.
        if (g_tags[s].va.compare_exchange_strong(expect, va,
                std::memory_order_acq_rel)) {
            g_tags[s].size = size;
            g_tags[s].caller = caller;
            g_tags[s].alloc_as = mmu::current_address_space();
            g_tag_live.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    }
    g_tag_full_drops.fetch_add(1, std::memory_order_relaxed);   // table full
}

// Classify a free of a possibly-tagged VA. Reads only BSS + current AS; never
// touches the chunk. Returns true if it was a tracked fallback.
inline bool on_free(void *p) {
    uintptr_t va = reinterpret_cast<uintptr_t>(p);
    unsigned h = hash_va(va);
    // Bounded probe: a miss within the window is harmless (the object is then
    // caught as leaked on reap -- a uniform bias that preserves the app/kernel
    // ratio). Bounding keeps free() O(1) despite tombstones.
    constexpr unsigned PROBE_MAX = 256;
    for (unsigned i = 0; i < PROBE_MAX; i++) {
        unsigned s = (h + i) & TAG_MASK;
        uintptr_t cur = g_tags[s].va.load(std::memory_order_acquire);
        if (cur == va) {
            unsigned long size = g_tags[s].size;
            uintptr_t caller = g_tags[s].caller;
            void *alloc_as = g_tags[s].alloc_as;
            void *cur_as = mmu::current_address_space();
            site *st = site_for(caller);
            if (cur_as == alloc_as) {
                st->freed_app_bytes.fetch_add(size, std::memory_order_relaxed);
                st->freed_app_count.fetch_add(1, std::memory_order_relaxed);
            } else {
                // freed by a DIFFERENT address space than allocated it: the
                // backend is gone (AS0 reaper / RCU / sibling) -> kernel-lifetime.
                st->freed_kern_bytes.fetch_add(size, std::memory_order_relaxed);
                st->freed_kern_count.fetch_add(1, std::memory_order_relaxed);
            }
            g_tags[s].va.store(TAG_TOMB, std::memory_order_release);
            g_tag_live.fetch_sub(1, std::memory_order_relaxed);
            return true;
        }
        if (cur == 0) return false;   // true empty slot: not tracked (past it is unused)
    }
    return false;
}

// On reap of address space @as, any tag still live with alloc_as==as was never
// freed by the backend -> it LEAKED. Bucket it by caller and clear it.
inline void on_reap(void *as) {
    for (unsigned s = 0; s < TAG_N; s++) {
        uintptr_t v = g_tags[s].va.load(std::memory_order_acquire);
        if (v > TAG_TOMB && g_tags[s].alloc_as == as) {
            site *st = site_for(g_tags[s].caller);
            st->leaked_bytes.fetch_add(g_tags[s].size, std::memory_order_relaxed);
            st->leaked_count.fetch_add(1, std::memory_order_relaxed);
            g_tags[s].va.store(0, std::memory_order_release);
            g_tag_live.fetch_sub(1, std::memory_order_relaxed);
        } else if (v == TAG_TOMB) {
            // recycle a tombstone to truly-empty during the full scan we are
            // already doing, so the bounded insert windows do not saturate.
            uintptr_t expect = TAG_TOMB;
            g_tags[s].va.compare_exchange_strong(expect, 0,
                    std::memory_order_acq_rel);
        }
    }
}

} // namespace fbhist

// C-linkage accessors for leak_probe.cc.
extern "C" void fbhist_totals(unsigned long *bytes, unsigned long *count,
                              unsigned long *live, unsigned long *drops) {
    if (bytes) *bytes = fbhist::g_fb_bytes.load(std::memory_order_relaxed);
    if (count) *count = fbhist::g_fb_count.load(std::memory_order_relaxed);
    if (live)  *live  = fbhist::g_tag_live.load(std::memory_order_relaxed);
    if (drops) *drops = fbhist::g_tag_full_drops.load(std::memory_order_relaxed);
}
// Dump the top sites by (leaked+kern) bytes into caller buffers. Returns count.
extern "C" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,
                                unsigned long *app_b, unsigned long *kern_b,
                                unsigned long *leak_b, unsigned max) {
    unsigned n = 0;
    for (unsigned i = 0; i < 512 && n < max; i++) {
        uintptr_t p = fbhist::g_sites[i].pc.load(std::memory_order_relaxed);
        if (!p) continue;
        pc[n]     = p;
        fb_b[n]   = fbhist::g_sites[i].fb_bytes.load(std::memory_order_relaxed);
        app_b[n]  = fbhist::g_sites[i].freed_app_bytes.load(std::memory_order_relaxed);
        kern_b[n] = fbhist::g_sites[i].freed_kern_bytes.load(std::memory_order_relaxed);
        leak_b[n] = fbhist::g_sites[i].leaked_bytes.load(std::memory_order_relaxed);
        n++;
    }
    return n;
}
// Reap hook exported to mmu.cc (called from destroy_address_space).
extern "C" void fbhist_on_reap(void *as) { fbhist::on_reap(as); }
#endif
"""
    m = m.replace(anchor, engine, 1)

    # Tag the fallback: capture caller PC and record. The fallback comment marks
    # the exact spot (we are past fork_arena::alloc returning nullptr).
    fb_anchor = "        // Arena could not serve it (too large / exhausted): fall through to the"
    if fb_anchor not in m:
        print("FATAL: fallback anchor not found"); sys.exit(1)
    # We need the pointer AFTER the identity alloc. Instead of tagging here (we
    # don't have the pointer yet), we tag at the return of std_malloc. Simplest:
    # set a per-thread flag + caller, and tag at the single return point. But
    # std_malloc has one 'return ret' at the end (plus the arena early return).
    # Use a local marker: remember we took the fallback + the caller PC.
    ins = ("        // LEAK #2 STEP 1: this app-thread alloc fell through the arena to the\n"
           "        // identity heap. Remember it so the single return point below can tag\n"
           "        // the resulting pointer with the caller PC for the histogram.\n"
           "        fb_took_fallback = true;\n"
           "        fb_caller = reinterpret_cast<uintptr_t>(__builtin_return_address(0));\n"
           + fb_anchor)
    m = m.replace(fb_anchor, ins, 1)

    # Declare the fallback locals at the top of std_malloc.
    sm_anchor = ("static inline void* std_malloc(size_t size, size_t alignment)\n"
                 "{\n"
                 "    if ((ssize_t)size < 0)\n"
                 "        return libc_error_ptr<void *>(ENOMEM);\n"
                 "    void *ret;\n")
    if sm_anchor not in m:
        print("FATAL: std_malloc head anchor not found"); sys.exit(1)
    m = m.replace(sm_anchor,
        sm_anchor +
        "#if CONF_fork\n"
        "    bool fb_took_fallback = false;\n"
        "    uintptr_t fb_caller = 0;\n"
        "#endif\n", 1)

    # Tag at the single tail return of std_malloc. The tail is:
    #   #if CONF_memory_tracker
    #       memory::tracker_remember(ret, size);
    #   #endif
    #       return ret;
    #   }
    # (the LAST such block in std_malloc). We insert before that return ret.
    tail_anchor = ("#if CONF_memory_tracker\n"
                   "    memory::tracker_remember(ret, size);\n"
                   "#endif\n"
                   "    return ret;\n"
                   "}\n\nvoid* calloc(size_t nmemb, size_t size)")
    if tail_anchor not in m:
        print("FATAL: std_malloc tail anchor not found"); sys.exit(1)
    m = m.replace(tail_anchor,
        "#if CONF_fork\n"
        "    if (fb_took_fallback && ret) {\n"
        "        fbhist::on_fallback(ret, size, fb_caller);\n"
        "    }\n"
        "#endif\n"
        "#if CONF_memory_tracker\n"
        "    memory::tracker_remember(ret, size);\n"
        "#endif\n"
        "    return ret;\n"
        "}\n\nvoid* calloc(size_t nmemb, size_t size)", 1)

    # Classify on free: at the top of free(), before the arena/linear dispatch,
    # check the tag table (only if NOT an arena chunk -- arena chunks are handled
    # by fork_arena and are not fallbacks). We probe on_free for identity VAs.
    free_anchor = ("#if CONF_fork\n"
                   "    // Fork-arena allocations live below phys_mem (so is_linear_mapped() is\n"
                   "    // false for them); dispatch them by address range BEFORE the linear-map\n"
                   "    // check so they never fall into the large/mmap free path.\n"
                   "    if (fork_arena::contains(object)) {\n"
                   "        return fork_arena::free(object);\n"
                   "    }\n"
                   "#endif")
    if free_anchor not in m:
        print("FATAL: free arena dispatch anchor not found"); sys.exit(1)
    m = m.replace(free_anchor,
        free_anchor +
        "\n#if CONF_fork\n"
        "    // LEAK #2 STEP 1: classify a free of a tracked identity-heap fallback\n"
        "    // (reads only BSS + current AS; never the chunk page). Does NOT change\n"
        "    // the free path -- the object is still freed normally below.\n"
        "    fbhist::on_free(object);\n"
        "#endif", 1)

    write(MEMPOOL, m)
    print("mempool.cc histogram engine applied")

# ---------------------------------------------------------------------------
# 2. mmu.cc: call fbhist_on_reap from destroy_address_space (before release_as).
# ---------------------------------------------------------------------------
mm = read(MMU)
if "fbhist_on_reap" in mm:
    print("mmu.cc already has reap hook")
else:
    reap_anchor = ("    // Reclaim this child's per-AS fork-arena free-list slot before the AS\n"
                   "    // object is freed, so the slot (keyed by this address_space*) can be reused\n"
                   "    // by a later fork child.\n"
                   "    fork_arena::release_as(as);")
    if reap_anchor not in mm:
        print("FATAL: mmu release_as anchor not found"); sys.exit(1)
    mm = mm.replace(reap_anchor,
        "    // LEAK #2 STEP 1: bucket any identity-heap fallback still live for this\n"
        "    // AS as LEAKED before the slot is dropped (measurement only).\n"
        "    fbhist_on_reap(as);\n" + reap_anchor, 1)
    # file-scope extern "C" decl (block scope is illegal) after the fork_arena include
    fa_inc = "#include <osv/fork_arena.hh>\n"
    if fa_inc not in mm:
        print("FATAL: mmu fork_arena include anchor not found"); sys.exit(1)
    mm = mm.replace(fa_inc,
        fa_inc + '#if CONF_fork\nextern "C" void fbhist_on_reap(void *as);  // LEAK #2 STEP 1 (core/mempool.cc)\n#endif\n', 1)
    write(MMU, mm)
    print("mmu.cc reap hook applied")

# ---------------------------------------------------------------------------
# 3. leak_probe.cc: dump the histogram periodically (top sites, app/kern/leak).
# ---------------------------------------------------------------------------
lp = read(LEAKPROBE)
if "fbhist_dump" in lp:
    print("leak_probe.cc already has histogram dump")
else:
    decl_anchor = 'extern "C" unsigned long leak_probe_gfdt_count(void);'
    if decl_anchor not in lp:
        print("FATAL: leak_probe gfdt decl anchor not found"); sys.exit(1)
    lp = lp.replace(decl_anchor,
        decl_anchor + "\n"
        "#if CONF_fork\n"
        '// LEAK #2 STEP 1 histogram accessors (core/mempool.cc).\n'
        'extern "C" void fbhist_totals(unsigned long *bytes, unsigned long *count,\n'
        '                              unsigned long *live, unsigned long *drops);\n'
        'extern "C" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,\n'
        '                                unsigned long *app_b, unsigned long *kern_b,\n'
        '                                unsigned long *leak_b, unsigned max);\n'
        "#endif", 1)

    # Add fb_bytes/live to the main LEAKPROBE line + a periodic FBHIST dump.
    read_anchor = "        { gfdt = leak_probe_gfdt_count(); }"
    if read_anchor not in lp:
        print("FATAL: leak_probe gfdt read anchor not found"); sys.exit(1)
    lp = lp.replace(read_anchor,
        read_anchor + "\n"
        "#if CONF_fork\n"
        "        unsigned long fb_bytes = 0, fb_count = 0, fb_live = 0, fb_drops = 0;\n"
        "        fbhist_totals(&fb_bytes, &fb_count, &fb_live, &fb_drops);\n"
        "#endif", 1)

    fmt_anchor = '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu\\n",'
    if fmt_anchor not in lp:
        print("FATAL: leak_probe printf fmt anchor not found"); sys.exit(1)
    lp = lp.replace(fmt_anchor,
        '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu "\n'
        '               "fb_bytes=%lu fb_mb=%lu fb_count=%lu fb_live=%lu fb_drops=%lu\\n",', 1)
    args_anchor = "               gc, gap, gpa, gfd, gsg);"
    if args_anchor not in lp:
        print("FATAL: leak_probe printf args anchor not found"); sys.exit(1)
    lp = lp.replace(args_anchor,
        "               gc, gap, gpa, gfd, gsg,\n"
        "#if CONF_fork\n"
        "               fb_bytes, fb_bytes >> 20, fb_count, fb_live, fb_drops\n"
        "#else\n"
        "               0UL, 0UL, 0UL, 0UL, 0UL\n"
        "#endif\n"
        "               );\n"
        "#if CONF_fork\n"
        "        // Periodic histogram: top caller sites by (leaked+kernel-freed) bytes,\n"
        "        // with the app-vs-kernel-lifetime split. Symbolize PCs offline via\n"
        "        // loader.elf (addr2line). Printed every 5 periods to limit console spam.\n"
        "        if ((t % 5) == 0) {\n"
        "            uintptr_t pc[64]; unsigned long fbb[64], appb[64], kernb[64], leakb[64];\n"
        "            unsigned n = fbhist_dump(pc, fbb, appb, kernb, leakb, 64);\n"
        "            for (unsigned i = 0; i < n; i++) {\n"
        "                if (fbb[i] == 0) continue;\n"
        "                printf(\"FBHIST t=%lu pc=%p fb_b=%lu app_b=%lu kern_b=%lu leak_b=%lu\\n\",\n"
        "                       t, (void*)pc[i], fbb[i], appb[i], kernb[i], leakb[i]);\n"
        "            }\n"
        "        }\n"
        "#endif", 1)
    write(LEAKPROBE, lp)
    print("leak_probe.cc histogram dump applied")

print("HISTOGRAM INSTRUMENT DONE")
