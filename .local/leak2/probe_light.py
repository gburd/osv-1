#!/usr/bin/env python3
# LEAK #2 validation LIGHT probe (OSV_LEAK_PROBE). Cheap single-atomic counters
# only -- NO tag table, NO per-reap sweep (those wedge the guest under the 32-way
# exhausted-arena storm; they were STEP-1 measurement only). Adds:
#   * fb_bytes/fb_count : app-thread allocations that STILL fell to the identity
#     heap. With the fix ON this must go to ~0 (the overflow region absorbs them);
#     with OSV_FORK_ARENA_RECLAIM=0 it climbs (the old leak). This is gate (a)/(e).
#   * ovf_bytes/ovf_count : bytes served from the per-AS overflow region (the fix
#     working). Grows post-exhaustion; reclaimed on reap so it is a RATE not a leak.
#   * recover_magic_mismatch : count (NOT assert) of fork_arena::recover() seeing a
#     bad magic -- i.e. a cross-AS free that reached recover() at a stale/unmapped
#     header. With the fix, overflow free() no-ops before recover(), so this MUST
#     stay 0. Any nonzero = the C2 hazard fired = gate (d) FAIL. Measurable, no crash.
# Idempotent.
import sys
MEMPOOL = "core/mempool.cc"
FA = "core/fork_arena.cc"
LEAKPROBE = "core/leak_probe.cc"

def read(p):
    with open(p, encoding="utf-8") as f: return f.read()
def write(p, s):
    with open(p, "w", encoding="utf-8") as f: f.write(s)

# ---- 1. mempool.cc: fb_bytes counter on the identity fallback ----
m = read(MEMPOOL)
if "g_app_fallback_bytes" in m:
    print("mempool.cc already has fb counter")
else:
    anchor = "#if CONF_fork\n#include <osv/fork_arena.hh>\n#include <osv/wait_record.hh>\n#endif\n"
    assert anchor in m, "mempool include anchor"
    m = m.replace(anchor, anchor + """
#if CONF_fork
// LEAK #2 validation: bytes/allocs an app thread requested that STILL fell to
// the IDENTITY heap (arena exhausted AND the per-AS overflow region could not
// serve). With OSV_FORK_ARENA_RECLAIM on this is ~0; with =0 it is the old leak.
#include <atomic>
std::atomic<unsigned long> g_app_fallback_bytes{0};
std::atomic<unsigned long> g_app_fallback_count{0};
extern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count) {
    if (bytes) *bytes = g_app_fallback_bytes.load(std::memory_order_relaxed);
    if (count) *count = g_app_fallback_count.load(std::memory_order_relaxed);
}
#endif
""", 1)
    fb_anchor = "        // Arena could not serve it (too large / exhausted): fall through to the"
    assert fb_anchor in m, "fallback anchor"
    m = m.replace(fb_anchor,
        "        // LEAK #2 validation: this app-thread alloc STILL fell to the identity\n"
        "        // heap (overflow region off or unavailable). Account it (the leak metric).\n"
        "        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
        "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
        + fb_anchor, 1)
    write(MEMPOOL, m)
    print("mempool.cc fb counter applied")

# ---- 2. fork_arena.cc: ovf byte counter + recover magic-mismatch COUNT ----
fa = read(FA)
if "g_ovf_bytes" in fa:
    print("fork_arena.cc already has ovf/magic counters")
else:
    # counters in the anonymous namespace, after g_reclaim_on block. Anchor on
    # the in_overflow() helper the fix added.
    anchor2 = "// BSS range check: is @p inside the per-AS overflow slot? Reads no arena page.\ninline bool in_overflow(const void *p)"
    assert anchor2 in fa, "in_overflow anchor (apply fix_real.py first)"
    fa = fa.replace(anchor2,
        "// LEAK #2 validation counters (single atomics, cheap).\n"
        "std::atomic<unsigned long> g_ovf_bytes{0};   // bytes served from overflow regions\n"
        "std::atomic<unsigned long> g_ovf_count{0};\n"
        "std::atomic<unsigned long> g_magic_mismatch{0}; // recover() saw a bad magic (gate d)\n\n"
        + anchor2, 1)
    # count overflow bytes at the overflow_alloc success sites. Simpler: count in
    # alloc() right after chunk = overflow_alloc(...). Anchor on that call.
    ov_anchor = ("            chunk = overflow_alloc(fl, class_size);\n"
                 "            if (!chunk) {\n"
                 "                return nullptr;   // could not map overflow: caller uses identity heap\n"
                 "            }")
    assert ov_anchor in fa, "overflow_alloc call anchor"
    fa = fa.replace(ov_anchor,
        "            chunk = overflow_alloc(fl, class_size);\n"
        "            if (!chunk) {\n"
        "                return nullptr;   // could not map overflow: caller uses identity heap\n"
        "            }\n"
        "            g_ovf_bytes.fetch_add(class_size, std::memory_order_relaxed);\n"
        "            g_ovf_count.fetch_add(1, std::memory_order_relaxed);", 1)
    # convert recover()'s assert(magic) into a COUNT (measurable, no abort). This
    # only ever fires for a NON-overflow chunk (overflow free no-ops before
    # recover), so a nonzero count = a real cross-AS header read = gate (d) FAIL.
    old_rec = "    assert(h->magic == chunk_magic);\n    s = h->class_shift;"
    assert old_rec in fa, "recover assert anchor"
    fa = fa.replace(old_rec,
        "    if (h->magic != chunk_magic) {\n"
        "        // LEAK #2 gate (d): a cross-AS free reached recover() at a stale/\n"
        "        // unmapped header. Count it (do NOT abort) so validation can see it.\n"
        "        g_magic_mismatch.fetch_add(1, std::memory_order_relaxed);\n"
        "        s = min_class_shift; base = reinterpret_cast<uintptr_t>(p); return;\n"
        "    }\n"
        "    s = h->class_shift;", 1)
    # accessor for leak_probe.cc
    end_ns = "} // namespace fork_arena\n"
    assert end_ns in fa, "namespace end"
    fa = fa.replace(end_ns,
        'extern "C" void fork_arena_probe(unsigned long *ovf_b, unsigned long *ovf_c,\n'
        '                                 unsigned long *magic) {\n'
        "    if (ovf_b)  *ovf_b  = g_ovf_bytes.load(std::memory_order_relaxed);\n"
        "    if (ovf_c)  *ovf_c  = g_ovf_count.load(std::memory_order_relaxed);\n"
        "    if (magic)  *magic  = g_magic_mismatch.load(std::memory_order_relaxed);\n"
        "}\n" + end_ns, 1)
    write(FA, fa)
    print("fork_arena.cc ovf/magic counters applied")

# ---- 3. leak_probe.cc: print fb_bytes + ovf_bytes + magic_mismatch ----
lp = read(LEAKPROBE)
if "fork_arena_probe" in lp:
    print("leak_probe.cc already has fix probe")
else:
    decl_anchor = 'extern "C" unsigned long leak_probe_gfdt_count(void);'
    assert decl_anchor in lp, "gfdt decl anchor"
    lp = lp.replace(decl_anchor, decl_anchor + "\n"
        "#if CONF_fork\n"
        '// LEAK #2 validation accessors.\n'
        'extern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count);\n'
        'extern "C" void fork_arena_probe(unsigned long *ovf_b, unsigned long *ovf_c, unsigned long *magic);\n'
        "#endif", 1)
    read_anchor = "        { gfdt = leak_probe_gfdt_count(); }"
    assert read_anchor in lp, "gfdt read anchor"
    lp = lp.replace(read_anchor, read_anchor + "\n"
        "#if CONF_fork\n"
        "        unsigned long fb_bytes = 0, fb_count = 0, ovf_bytes = 0, ovf_count = 0, magic_mm = 0;\n"
        "        leak_probe_app_fallback(&fb_bytes, &fb_count);\n"
        "        fork_arena_probe(&ovf_bytes, &ovf_count, &magic_mm);\n"
        "#endif", 1)
    fmt_anchor = '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu\\n",'
    assert fmt_anchor in lp, "printf fmt anchor"
    lp = lp.replace(fmt_anchor,
        '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu "\n'
        '               "fb_mb=%lu fb_count=%lu ovf_mb=%lu ovf_count=%lu magic_mm=%lu\\n",', 1)
    args_anchor = "               gc, gap, gpa, gfd, gsg);"
    assert args_anchor in lp, "printf args anchor"
    lp = lp.replace(args_anchor,
        "               gc, gap, gpa, gfd, gsg\n"
        "#if CONF_fork\n"
        "               , fb_bytes >> 20, fb_count, ovf_bytes >> 20, ovf_count, magic_mm\n"
        "#else\n"
        "               , 0UL, 0UL, 0UL, 0UL, 0UL\n"
        "#endif\n"
        "               );", 1)
    write(LEAKPROBE, lp)
    print("leak_probe.cc fix probe applied")
print("VALIDATION LIGHT PROBE DONE")
