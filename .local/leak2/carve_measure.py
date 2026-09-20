#!/usr/bin/env python3
# LEAK #2 carve-pattern MEASUREMENT instrument (no fix, pure measurement).
#
# Question the corrected design hinges on: when a fork child AS is reaped
# (release_as), is its carved arena VA region reclaimable AT THE TOP of g_bump
# (so a bounded g_bump REWIND keeps the arena from exhausting, WITHOUT ever
# reissuing one AS's VA to another AS), or is it BURIED under still-live younger
# carves (interleaved -> a simple top-rewind reclaims little)?
#
# We track, per AS, the [lo,hi) VA range it has carved off g_bump (hi = highest
# g_bump value this AS bumped to). On release_as we classify:
#   - TOP:    the dying AS's carve_hi == current g_bump  -> its whole carve is at
#             the top, immediately rewindable. We simulate a greedy rewind
#             (rewind g_bump past every contiguous fully-dead top region) and
#             count reclaimed bytes.
#   - BURIED: carve_hi < g_bump  -> a younger AS carved above it; not top-
#             rewindable now (but may become rewindable once the younger ones
#             die, if reaps are LIFO-ish).
# Emits a REWIND line in the LEAKPROBE cadence: total carved, live carve high-
# water, bytes a greedy top-rewind would have reclaimed cumulatively, and the
# TOP vs BURIED reap tally. If greedy-reclaimed tracks total-carved (arena stays
# bounded), the rewind fix is viable. If reclaimed stays ~0 while carved climbs,
# reaps are interleaved and top-rewind won't save it.
#
# Fixed BSS, no dynamic alloc. Idempotent.
import sys
FA="core/fork_arena.cc"; HH="include/osv/fork_arena.hh"; LP="core/leak_probe.cc"
def rd(p):
    with open(p, encoding="utf-8") as f: return f.read()
def wr(p,s):
    with open(p,"w",encoding="utf-8") as f: f.write(s)

fa=rd(FA)
if "carve_measure" in fa: print("fork_arena.cc already measured"); sys.exit(0)

# 1. Per-AS carve tracking table + counters, in the anon namespace after g_slot_lock.
anchor="spinlock g_slot_lock;   // guards slot acquisition only (rare: once per AS)"
if anchor not in fa: print("FATAL slot_lock anchor"); sys.exit(1)
tbl=anchor + r'''

// ---- LEAK #2 carve_measure: per-AS carve [lo,hi) watermark + rewind sim ----
struct carve_rec { void *as; uintptr_t lo; uintptr_t hi; bool live; };
constexpr unsigned MAX_CARVE = 4096;   // distinct AS carve records ever (cap)
carve_rec g_carve[MAX_CARVE];
unsigned  g_carve_n = 0;                // high-water of used records
spinlock  g_carve_lock;
std::atomic<unsigned long> g_carve_total{0};   // sum of all bytes ever carved
std::atomic<unsigned long> g_rewind_reclaimed{0}; // bytes a greedy top-rewind freed
std::atomic<unsigned long> g_reap_top{0};      // reaps whose carve was at the top
std::atomic<unsigned long> g_reap_buried{0};   // reaps buried under younger carves
std::atomic<unsigned long> g_reap_nocarve{0};  // reaped AS that never carved

carve_rec *carve_find(void *as, bool create){
    for (unsigned i=0;i<g_carve_n;i++) if (g_carve[i].as==as) return &g_carve[i];
    if (!create) return nullptr;
    if (g_carve_n>=MAX_CARVE) return nullptr;
    carve_rec *r=&g_carve[g_carve_n++];
    r->as=as; r->lo=0; r->hi=0; r->live=true;
    return r;
}
// Called right after a successful bump carve: record [c, c+sz) for this AS.
void carve_note(void *as, uintptr_t c, size_t sz){
    SCOPE_LOCK(g_carve_lock);
    carve_rec *r=carve_find(as, true);
    if (!r) return;
    if (r->lo==0 || c < r->lo) r->lo=c;
    if (c+sz > r->hi) r->hi=c+sz;
    r->live=true;
    g_carve_total.fetch_add(sz, std::memory_order_relaxed);
}
'''
fa=fa.replace(anchor, tbl, 1)

# 2. record the carve in alloc() right after the successful fetch_add.
carve_site=("        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);\n"
            "        if (c + class_size > g_end) {\n"
            "            return nullptr;   // arena exhausted\n"
            "        }\n"
            "        chunk = reinterpret_cast<void*>(c);")
if carve_site not in fa: print("FATAL carve site"); sys.exit(1)
carve_site_new=("        uintptr_t c = g_bump.fetch_add(class_size, std::memory_order_relaxed);\n"
            "        if (c + class_size > g_end) {\n"
            "            return nullptr;   // arena exhausted\n"
            "        }\n"
            "        carve_note(mmu::current_address_space(), c, class_size);\n"
            "        chunk = reinterpret_cast<void*>(c);")
fa=fa.replace(carve_site, carve_site_new, 1)

# 3. In release_as, classify the reap + simulate greedy top-rewind. Insert before
#    the existing slot-clearing loop's return (i.e. at the top of release_as body).
ra_anchor=("    if (!g_ready.load(std::memory_order_acquire)) {\n        return;\n    }\n    SCOPE_LOCK(g_slot_lock);")
if ra_anchor not in fa: print("FATAL release_as anchor"); sys.exit(1)
ra_new=("    if (!g_ready.load(std::memory_order_acquire)) {\n        return;\n    }\n"
    "    // carve_measure: classify this reap (TOP vs BURIED) + simulate a greedy\n"
    "    // top-rewind of g_bump past every contiguous fully-dead top region.\n"
    "    {\n"
    "        SCOPE_LOCK(g_carve_lock);\n"
    "        carve_rec *r=carve_find(as, false);\n"
    "        if (!r) { g_reap_nocarve.fetch_add(1, std::memory_order_relaxed); }\n"
    "        else {\n"
    "            r->live=false;\n"
    "            uintptr_t bump=g_bump.load(std::memory_order_relaxed);\n"
    "            if (r->hi==bump) g_reap_top.fetch_add(1, std::memory_order_relaxed);\n"
    "            else             g_reap_buried.fetch_add(1, std::memory_order_relaxed);\n"
    "            // greedy rewind: repeatedly, if some dead record ends exactly at\n"
    "            // the current (simulated) bump, rewind past it. O(n^2) worst but\n"
    "            // n is small and this is measurement only.\n"
    "            uintptr_t sim=bump; bool moved=true;\n"
    "            while (moved) {\n"
    "                moved=false;\n"
    "                for (unsigned i=0;i<g_carve_n;i++){\n"
    "                    if (!g_carve[i].live && g_carve[i].hi==sim && g_carve[i].hi>g_carve[i].lo){\n"
    "                        g_rewind_reclaimed.fetch_add((unsigned long)(g_carve[i].hi-g_carve[i].lo), std::memory_order_relaxed);\n"
    "                        sim=g_carve[i].lo;\n"
    "                        g_carve[i].hi=g_carve[i].lo; // consumed by the sim rewind\n"
    "                        moved=true;\n"
    "                    }\n"
    "                }\n"
    "            }\n"
    "        }\n"
    "    }\n"
    "    SCOPE_LOCK(g_slot_lock);")
fa=fa.replace(ra_anchor, ra_new, 1)

# 4. Expose the counters via a probe accessor.
probe_end="} // namespace fork_arena"
if probe_end not in fa: print("FATAL ns end"); sys.exit(1)
probe=("void leak_probe_carve(unsigned long *carved, unsigned long *reclaimed,\n"
       "                       unsigned long *reap_top, unsigned long *reap_buried,\n"
       "                       unsigned long *reap_nocarve, unsigned long *carve_recs)\n"
       "{\n"
       "    if (carved)   *carved   = g_carve_total.load(std::memory_order_relaxed);\n"
       "    if (reclaimed)*reclaimed= g_rewind_reclaimed.load(std::memory_order_relaxed);\n"
       "    if (reap_top) *reap_top = g_reap_top.load(std::memory_order_relaxed);\n"
       "    if (reap_buried)*reap_buried=g_reap_buried.load(std::memory_order_relaxed);\n"
       "    if (reap_nocarve)*reap_nocarve=g_reap_nocarve.load(std::memory_order_relaxed);\n"
       "    if (carve_recs)*carve_recs=g_carve_n;\n"
       "}\n\n")
fa=fa.replace(probe_end, probe+probe_end, 1)
wr(FA,fa); print("fork_arena.cc carve_measure applied")

# 5. leak_probe.cc: declare + read + print the carve fields.
lp=rd(LP)
if "leak_probe_carve" in lp: print("leak_probe.cc already measured"); sys.exit(0)
d_anchor='extern "C" unsigned long leak_probe_gfdt_count(void);'
if d_anchor not in lp: print("FATAL lp decl anchor"); sys.exit(1)
lp=lp.replace(d_anchor, d_anchor+'\n// leak #2 carve_measure (core/fork_arena.cc)\nextern "C" void leak_probe_carve(unsigned long*,unsigned long*,unsigned long*,unsigned long*,unsigned long*,unsigned long*);',1)
r_anchor="        { gfdt = leak_probe_gfdt_count(); }"
if r_anchor not in lp: print("FATAL lp read anchor"); sys.exit(1)
lp=lp.replace(r_anchor, r_anchor+"\n        unsigned long cv=0,rc=0,rt=0,rb=0,rn=0,crn=0;\n        leak_probe_carve(&cv,&rc,&rt,&rb,&rn,&crn);",1)
f_anchor='               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu\\n",'
if f_anchor not in lp: print("FATAL lp fmt anchor"); sys.exit(1)
lp=lp.replace(f_anchor,
    '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu "\n'
    '               "carved_mb=%lu rewound_mb=%lu reap_top=%lu reap_buried=%lu reap_nocarve=%lu carve_recs=%lu\\n",',1)
a_anchor="               gc, gap, gpa, gfd, gsg);"
if a_anchor not in lp: print("FATAL lp args anchor"); sys.exit(1)
lp=lp.replace(a_anchor,
    "               gc, gap, gpa, gfd, gsg,\n"
    "               cv>>20, rc>>20, rt, rb, rn, crn);",1)
wr(LP,lp); print("leak_probe.cc carve_measure applied")
print("CARVE MEASURE DONE")
