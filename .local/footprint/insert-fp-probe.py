#!/usr/bin/env python3
# FOOTPRINT PROBE (OSV_FP_PROBE=1): per-backend private-memory attribution.
#
# Counts, globally and PER ADDRESS SPACE:
#   (a) COW write faults bucketed by VA slot (arena=96, overflow=97, ELF=32,
#       mmap-hole=64..95, other) -- the pages a forked backend MATERIALIZES
#   (b) page-table pages allocated per clone_address_space (PML4 + L2 + L1 + leaf)
#   (c) privatized (byte-copied) stack pages per clone
#   + the arena bump high-water (how much arena VA is carved at all)
#   + free memory so the residual (d) falls out of the accounting
# A kernel dumper thread (started from loader.cc, AS0) prints the table every
# OSV_FP_INTERVAL seconds. Self-contained: no ZFS/openzfs dependency.
# Idempotent; env-gated; ~one relaxed load per COW fault when off.
import sys

MMU = "/work/osv/core/mmu.cc" if len(sys.argv) < 2 else sys.argv[1]
LOADER = "/work/osv/loader.cc" if len(sys.argv) < 3 else sys.argv[2]
MMUHH = MMU.replace("core/mmu.cc", "include/osv/mmu.hh")
ARENA = MMU.replace("core/mmu.cc", "core/fork_arena.cc")
ARENAHH = MMU.replace("core/mmu.cc", "include/osv/fork_arena.hh")

s = open(MMU).read()
if "fp_count_cow" in s:
    print("FP PROBE ALREADY PRESENT IN MMU")
else:
    CORE = r'''
// -----------------------------------------------------------------------------
// FOOTPRINT PROBE (OSV_FP_PROBE=1): attribute a fork child's PRIVATE memory.
//
// Counted at the exact site that MATERIALIZES a page:
//   (a) COW write faults        -> handle_cow_write_fault, bucketed by VA slot
//   (b) page-table clone pages  -> the alloc_page()s in the clone walk
//   (c) privatized stack pages  -> clone_pt_level0's addr_is_privatize byte copy
// Per-AS rows are keyed on the address_space* so a per-backend number falls out.
// State is plain kernel BSS (identity-mapped, shared verbatim in every AS), so a
// forked child's increment is visible to the AS0 dumper thread.
// -----------------------------------------------------------------------------
namespace fp {

enum bucket { B_ARENA = 0, B_OVF, B_ELF, B_MMAP, B_OTHER, B_NBUCKET };

struct as_row {
    std::atomic<void*> owner{nullptr};
    std::atomic<u64> cow[B_NBUCKET];
    std::atomic<u64> pt_pages{0};
    std::atomic<u64> priv_pages{0};
    std::atomic<u64> ovf_pages{0};
};
constexpr unsigned max_rows = 512;
as_row rows[max_rows];
std::atomic<u64> g_cow[B_NBUCKET];
std::atomic<u64> g_pt_pages{0};
std::atomic<u64> g_priv_pages{0};
std::atomic<u64> g_forks{0};
std::atomic<u64> g_reaps{0};
// Retired (reaped) children's totals, so the accounting still balances after
// a backend exits.
std::atomic<u64> r_cow[B_NBUCKET];
std::atomic<u64> r_pt{0};
std::atomic<u64> r_priv{0};
std::atomic<int> g_on{-1};

bool on()
{
    int v = g_on.load(std::memory_order_relaxed);
    if (v < 0) {
        const char *e = getenv("OSV_FP_PROBE");
        v = (e && e[0] && e[0] != '0') ? 1 : 0;
        g_on.store(v, std::memory_order_relaxed);
    }
    return v != 0;
}

inline bucket bucket_for(uintptr_t va)
{
    unsigned slot = (unsigned)(va >> 39);
    if (slot == 96) return B_ARENA;
    if (slot == 97) return B_OVF;
    if (slot == 32) return B_ELF;
    if (slot >= 64 && slot <= 95) return B_MMAP;
    return B_OTHER;
}

as_row *row_for(void *as)
{
    if (!as) return nullptr;
    for (unsigned i = 0; i < max_rows; i++) {
        if (rows[i].owner.load(std::memory_order_acquire) == as) return &rows[i];
    }
    for (unsigned i = 0; i < max_rows; i++) {
        void *e = nullptr;
        if (rows[i].owner.compare_exchange_strong(e, as, std::memory_order_acq_rel)) {
            for (unsigned b = 0; b < B_NBUCKET; b++) {
                rows[i].cow[b].store(0, std::memory_order_relaxed);
            }
            rows[i].pt_pages.store(0, std::memory_order_relaxed);
            rows[i].priv_pages.store(0, std::memory_order_relaxed);
            rows[i].ovf_pages.store(0, std::memory_order_relaxed);
            return &rows[i];
        }
    }
    return nullptr;
}

void release_row(void *as)
{
    for (unsigned i = 0; i < max_rows; i++) {
        if (rows[i].owner.load(std::memory_order_relaxed) == as) {
            for (unsigned b = 0; b < B_NBUCKET; b++) {
                r_cow[b].fetch_add(rows[i].cow[b].load(std::memory_order_relaxed),
                                   std::memory_order_relaxed);
            }
            r_pt.fetch_add(rows[i].pt_pages.load(std::memory_order_relaxed),
                           std::memory_order_relaxed);
            r_priv.fetch_add(rows[i].priv_pages.load(std::memory_order_relaxed),
                             std::memory_order_relaxed);
            rows[i].owner.store(nullptr, std::memory_order_release);
            return;
        }
    }
}

} // namespace fp

static inline void fp_count_cow(uintptr_t va)
{
    if (!fp::on()) return;
    fp::bucket b = fp::bucket_for(va);
    fp::g_cow[b].fetch_add(1, std::memory_order_relaxed);
    auto *r = fp::row_for(current_address_space());
    if (r) r->cow[b].fetch_add(1, std::memory_order_relaxed);
}
static inline void fp_count_pt(void *child_as, u64 n)
{
    if (!fp::on()) return;
    fp::g_pt_pages.fetch_add(n, std::memory_order_relaxed);
    auto *r = fp::row_for(child_as);
    if (r) r->pt_pages.fetch_add(n, std::memory_order_relaxed);
}
static inline void fp_count_priv(void *child_as, u64 n)
{
    if (!fp::on()) return;
    fp::g_priv_pages.fetch_add(n, std::memory_order_relaxed);
    auto *r = fp::row_for(child_as);
    if (r) r->priv_pages.fetch_add(n, std::memory_order_relaxed);
}
'''
    anchor = "struct address_space {"
    assert anchor in s, "address_space struct anchor missing"
    s = s.replace(anchor,
        "// FOOTPRINT PROBE forward decl (defined below).\n"
        "address_space *current_address_space();\n"
        + CORE + "\n" + anchor, 1)

    # hook the COW fault
    a2 = """    if (!pte_is_cow(e0)) return false;

    // Copy the shared page into a fresh private page."""
    assert a2 in s, "cow fault anchor missing"
    s = s.replace(a2, """    if (!pte_is_cow(e0)) return false;

    // FOOTPRINT PROBE: this fault MATERIALIZES a private page -- attribute it.
    fp_count_cow(addr);

    // Copy the shared page into a fresh private page.""", 1)

    # force per-fork stats when the probe is on
    a3 = "        cur_fork_stats = ftime ? &fst : nullptr;"
    assert a3 in s, "cur_fork_stats anchor missing"
    s = s.replace(a3, "        cur_fork_stats = (ftime || fp::on()) ? &fst : nullptr;", 1)

    # per-AS tally at the end of clone_address_space
    a4 = """        debug_early_u64("  n_lg_shared=", fst.n_large_shared);
    }
    return child;"""
    assert a4 in s, "fork stats dump anchor missing"
    s = s.replace(a4, """        debug_early_u64("  n_lg_shared=", fst.n_large_shared);
    }
    // FOOTPRINT PROBE: attribute this clone's page-table + privatized-page cost
    // to the CHILD address space (the (b) and (c) terms of the breakdown).
    if (fp::on()) {
        fp::g_forks.fetch_add(1, std::memory_order_relaxed);
        // fst.n_tables counts every L1 + leaf table the walk allocated; add the
        // cloned app PML4 slots (each = one L2 table) and the child's PML4 page.
        fp_count_pt(child, fst.n_tables + fst.n_pml4_slots + 1);
        fp_count_priv(child, fst.n_priv_copies);
    }
    return child;""", 1)

    # count L2 tables (one per cloned app PML4 slot)
    a5 = "    u64 n_lookup_true = 0; // lookups that HIT a range"
    assert a5 in s
    s = s.replace(a5, a5 + """
    u64 n_pml4_slots = 0;  // FOOTPRINT PROBE: cloned app PML4 slots (= L2 tables)""", 1)
    a6 = """                clone_pt_level<2>(parent_sub, static_cast<pt_element<2>*>(child_sub),
                                  (uintptr_t)slot << 39);"""
    assert a6 in s, "pml4 slot clone anchor missing"
    s = s.replace(a6, """                if (cur_fork_stats) cur_fork_stats->n_pml4_slots++;
                clone_pt_level<2>(parent_sub, static_cast<pt_element<2>*>(child_sub),
                                  (uintptr_t)slot << 39);""", 1)

    # count the L1 tables allocated in clone_pt_level<2>
    a7 = """        if (ppte.large()) { child_pt[i] = ppte; continue; }
        void *child_sub = memory::alloc_page();
        memset(child_sub, 0, page_size);
        auto parent_sub = phys_cast<pt_element<1>>(ppte.next_pt_addr());"""
    assert a7 in s, "level2 alloc anchor missing"
    s = s.replace(a7, """        if (ppte.large()) { child_pt[i] = ppte; continue; }
        void *child_sub = memory::alloc_page();
        memset(child_sub, 0, page_size);
        if (cur_fork_stats) cur_fork_stats->n_tables++;   // FOOTPRINT PROBE: L1 table
        auto parent_sub = phys_cast<pt_element<1>>(ppte.next_pt_addr());""", 1)

    # release the row on reap
    a8 = """    fork_arena::release_as(as);
    delete as;"""
    assert a8 in s, "destroy_address_space anchor missing"
    s = s.replace(a8, """    fork_arena::release_as(as);
    if (fp::on()) {
        fp::g_reaps.fetch_add(1, std::memory_order_relaxed);
        fp::release_row(as);
    }
    delete as;""", 1)

    # the dumper (inside namespace mmu, at file end) + its thread
    DUMP = r'''
// FOOTPRINT PROBE dumper: one FPROW line per live AS plus an FPTOT summary,
// every OSV_FP_INTERVAL seconds from an AS0 kernel thread.  Started by
// fp_probe_start() from loader.cc after fork_arena::init().
void fp_dump_once()
{
    u64 t_cow[fp::B_NBUCKET] = {0};
    u64 t_pt = 0, t_priv = 0, t_ovf = 0;
    unsigned live = 0;
    for (unsigned i = 0; i < fp::max_rows; i++) {
        void *o = fp::rows[i].owner.load(std::memory_order_acquire);
        if (!o) continue;
        u64 c[fp::B_NBUCKET];
        for (unsigned b = 0; b < fp::B_NBUCKET; b++) {
            c[b] = fp::rows[i].cow[b].load(std::memory_order_relaxed);
            t_cow[b] += c[b];
        }
        u64 pt = fp::rows[i].pt_pages.load(std::memory_order_relaxed);
        u64 pv = fp::rows[i].priv_pages.load(std::memory_order_relaxed);
        u64 ov = fp::rows[i].ovf_pages.load(std::memory_order_relaxed);
        t_pt += pt; t_priv += pv; t_ovf += ov;
        live++;
        // KB per term for this AS (4 KB pages).
        debugf("FPROW as=%p cowarena_KB=%d cowovf_KB=%d cowelf_KB=%d cowmmap_KB=%d "
               "cowoth_KB=%d pt_KB=%d priv_KB=%d ovf_KB=%d tot_KB=%d\n", o,
               (int)(c[fp::B_ARENA] * 4), (int)(c[fp::B_OVF] * 4),
               (int)(c[fp::B_ELF] * 4),   (int)(c[fp::B_MMAP] * 4),
               (int)(c[fp::B_OTHER] * 4), (int)(pt * 4), (int)(pv * 4), (int)(ov * 4),
               (int)((c[fp::B_ARENA] + c[fp::B_OVF] + c[fp::B_ELF] + c[fp::B_MMAP] +
                      c[fp::B_OTHER] + pt + pv + ov) * 4));
    }
    u64 acc = 0;
    for (unsigned b = 0; b < fp::B_NBUCKET; b++) acc += t_cow[b];
    acc += t_pt + t_priv + t_ovf;
    // Per-backend average over live CHILD address spaces (live-1 excludes AS0,
    // which holds no row unless it COW-faulted; guard anyway).
    unsigned kids = live ? live : 1;
    debugf("FPTOT live_as=%d forks=%d reaps=%d "
           "cowarena_MB=%d cowovf_MB=%d cowelf_MB=%d cowmmap_MB=%d cowoth_MB=%d "
           "pt_MB=%d priv_MB=%d ovf_MB=%d acct_MB=%d per_as_KB=%d "
           "retired_cowarena_MB=%d retired_pt_MB=%d "
           "arena_bump_MB=%d arena_slots=%d memfree_MB=%d memtotal_MB=%d\n",
           (int)live, (int)fp::g_forks.load(std::memory_order_relaxed),
           (int)fp::g_reaps.load(std::memory_order_relaxed),
           (int)((t_cow[fp::B_ARENA] * 4) >> 10), (int)((t_cow[fp::B_OVF] * 4) >> 10),
           (int)((t_cow[fp::B_ELF] * 4) >> 10),   (int)((t_cow[fp::B_MMAP] * 4) >> 10),
           (int)((t_cow[fp::B_OTHER] * 4) >> 10),
           (int)((t_pt * 4) >> 10), (int)((t_priv * 4) >> 10), (int)((t_ovf * 4) >> 10),
           (int)((acc * 4) >> 10), (int)((acc * 4) / kids),
           (int)((fp::r_cow[fp::B_ARENA].load(std::memory_order_relaxed) * 4) >> 10),
           (int)((fp::r_pt.load(std::memory_order_relaxed) * 4) >> 10),
           (int)(fork_arena::bump_used() >> 20), (int)fork_arena::live_as_slots(),
           (int)(memory::stats::free() >> 20), (int)(memory::stats::total() >> 20));
}

void fp_probe_start()
{
    if (!fp::on()) return;
    const char *e = getenv("OSV_FP_INTERVAL");
    int iv = (e && e[0]) ? atoi(e) : 5;
    if (iv < 1) iv = 1;
    debugf("FPPROBE started interval=%ds\n", iv);
    auto *t = new sched::thread([iv] {
        for (;;) {
            sched::thread::sleep(std::chrono::seconds(iv));
            fp_dump_once();
        }
    }, sched::thread::attr().name("fp_probe").detached());
    t->start();
}
'''
    s = s + "\nnamespace mmu {\n" + DUMP + "}\n"
    open(MMU, "w").write(s)
    print("FP PROBE APPLIED OK (mmu.cc)")

# ------------------------------------------------ arena bump high-water accessor
A = open(ARENA).read()
if "fork_arena_bump_used" in A:
    print("ARENA ACCESSOR ALREADY PRESENT")
else:
    a = "bool ready()\n{"
    assert a in A, "fork_arena ready() anchor missing"
    A = A.replace(a, """// FOOTPRINT PROBE: bytes of arena VA carved off the GLOBAL bump so far (the
// high-water of never-yet-reused arena space).  Read-only; no locks.
size_t bump_used()
{
    if (!g_ready.load(std::memory_order_acquire)) return 0;
    uintptr_t b = g_bump.load(std::memory_order_relaxed);
    return (b > arena_base) ? (size_t)(b - arena_base) : 0;
}

// FOOTPRINT PROBE: count of per-AS free-list slots in use (== live processes
// that have allocated from the arena).
unsigned live_as_slots()
{
    unsigned n = 0;
    for (unsigned i = 0; i < max_as_slots; i++) {
        if (g_as_freelists[i].owner.load(std::memory_order_relaxed)) n++;
    }
    return n;
}

""" + a, 1)
    open(ARENA, "w").write(A)
    print("ARENA ACCESSOR APPLIED OK")

AH = open(ARENAHH).read()
if "fork_arena_bump_used" in AH or "size_t bump_used" in AH:
    print("ARENA HH ALREADY DECLARED")
else:
    ah = "// Usable size of an arena allocation"
    assert ah in AH, "fork_arena.hh anchor missing"
    AH = AH.replace(ah, """// FOOTPRINT PROBE: bytes of arena VA carved off the global bump (high-water),
// and the count of live per-AS free-list slots.
size_t bump_used();
unsigned live_as_slots();

""" + ah, 1)
    open(ARENAHH, "w").write(AH)
    print("ARENA HH APPLIED OK")

# ------------------------------------------------- declare fp_probe_start in mmu.hh
H = open(MMUHH).read()
if "fp_probe_start" in H:
    print("MMU HH ALREADY DECLARED")
else:
    h = "std::string procfs_maps();"
    assert h in H, "mmu.hh anchor missing"
    H = H.replace(h, """// FOOTPRINT PROBE (OSV_FP_PROBE=1): start the per-address-space private-memory
// attribution dumper thread.  No-op when the probe is off.
void fp_probe_start();

""" + h, 1)
    open(MMUHH, "w").write(H)
    print("MMU HH APPLIED OK")

# ---------------------------------------------------------------- loader hook
L = open(LOADER).read()
if "fp_probe_start" in L:
    print("FP PROBE ALREADY WIRED IN LOADER"); sys.exit(0)
a = "    fork_arena::init();"
assert a in L, "loader fork_arena::init anchor missing"
L = L.replace(a, a + """
    // FOOTPRINT PROBE (OSV_FP_PROBE=1): start the per-AS attribution dumper.
    mmu::fp_probe_start();""", 1)
open(LOADER, "w").write(L)
print("FP PROBE WIRED IN LOADER OK")
