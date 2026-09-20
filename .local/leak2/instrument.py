#!/usr/bin/env python3
# Leak #2 LOCALIZATION instrument. Adds counters that measure how many bytes an
# APP thread allocated that fell THROUGH the fork arena to the identity kernel
# heap (arena exhausted / too big). Those identity-heap allocations are not tied
# to the child address_space, so destroy_address_space() on reap does not free
# them -> the hypothesized leak. If g_app_fallback_bytes grows ~1MB per reaped
# backend and tracks the mem_free drop, the hypothesis is CONFIRMED.
#
# Idempotent: bails if the marker is already present.
import re, sys, io

MEMPOOL = "core/mempool.cc"
LEAKPROBE = "core/leak_probe.cc"

def read(p):
    with open(p, encoding="utf-8") as f: return f.read()
def write(p, s):
    with open(p, "w", encoding="utf-8") as f: f.write(s)

# ---- 1. mempool.cc: counters + increment on the arena-exhausted fallback ----
m = read(MEMPOOL)
if "g_app_fallback_bytes" in m:
    print("mempool.cc already instrumented"); 
else:
    # Add the counter definitions right after the fork_arena include block.
    anchor = "#if CONF_fork\n#include <osv/fork_arena.hh>\n#include <osv/wait_record.hh>\n#endif\n"
    if anchor not in m:
        print("FATAL: mempool include anchor not found"); sys.exit(1)
    defs = anchor + """
#if CONF_fork
// ---- leak #2 localization (OSV_LEAK_PROBE) --------------------------------
// Cumulative bytes/allocs an APP thread requested that could NOT be served by
// the fork arena (exhausted or too large) and thus fell through to the IDENTITY
// kernel heap. Identity-heap allocations are shared verbatim across every
// address space and are NOT freed by destroy_address_space() on backend reap,
// so a forked+reaped backend's fallback allocations LEAK. This counter names
// the leak: its growth rate vs mem_free's drop rate is the confirming A/B.
#include <atomic>
std::atomic<unsigned long> g_app_fallback_bytes{0};
std::atomic<unsigned long> g_app_fallback_count{0};
extern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count) {
    if (bytes) *bytes = g_app_fallback_bytes.load(std::memory_order_relaxed);
    if (count) *count = g_app_fallback_count.load(std::memory_order_relaxed);
}
#endif
"""
    m = m.replace(anchor, defs, 1)

    # Increment on the fallback path: the app-thread arena branch that fell
    # through. The unique marker is the comment "Arena could not serve it".
    fb_anchor = "        // Arena could not serve it (too large / exhausted): fall through to the"
    if fb_anchor not in m:
        print("FATAL: fallback anchor not found"); sys.exit(1)
    # Insert the accounting just before the comment (still inside the app-thread
    # `if (ret) return;` block's else path: we only reach here when ret==nullptr).
    ins = ("        // LEAK #2 PROBE: this app-thread allocation fell through the arena to the\n"
           "        // identity heap; it will not be freed on reap. Account it.\n"
           "        g_app_fallback_bytes.fetch_add(size, std::memory_order_relaxed);\n"
           "        g_app_fallback_count.fetch_add(1, std::memory_order_relaxed);\n"
           + fb_anchor)
    m = m.replace(fb_anchor, ins, 1)
    write(MEMPOOL, m)
    print("mempool.cc instrumented OK")

# ---- 2. leak_probe.cc: print the counters in the LEAKPROBE line ----
lp = read(LEAKPROBE)
if "app_fallback" in lp:
    print("leak_probe.cc already instrumented")
else:
    # declare the accessor near the gfdt one
    decl_anchor = 'extern "C" unsigned long leak_probe_gfdt_count(void);'
    if decl_anchor not in lp:
        print("FATAL: leak_probe gfdt decl anchor not found"); sys.exit(1)
    lp = lp.replace(decl_anchor,
        decl_anchor + '\n// leak #2: app-thread identity-heap fallback bytes/count (core/mempool.cc)\nextern "C" void leak_probe_app_fallback(unsigned long *bytes, unsigned long *count);',
        1)
    # read them inside the loop, after the gfdt read
    read_anchor = "        { gfdt = leak_probe_gfdt_count(); }"
    if read_anchor not in lp:
        print("FATAL: leak_probe gfdt read anchor not found"); sys.exit(1)
    lp = lp.replace(read_anchor,
        read_anchor + "\n        unsigned long fb_bytes = 0, fb_count = 0;\n        leak_probe_app_fallback(&fb_bytes, &fb_count);",
        1)
    # add to the printf format + args. The LEAKPROBE printf ends its format with
    # the g_sigtables field; append fallback fields.
    fmt_anchor = '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu\\n",'
    if fmt_anchor not in lp:
        print("FATAL: leak_probe printf fmt anchor not found"); sys.exit(1)
    lp = lp.replace(fmt_anchor,
        '               "g_children=%lu g_as_pid=%lu g_pid_as=%lu g_inherited=%lu g_sigtables=%lu "\n'
        '               "fb_bytes=%lu fb_mb=%lu fb_count=%lu\\n",', 1)
    args_anchor = "               gc, gap, gpa, gfd, gsg);"
    if args_anchor not in lp:
        print("FATAL: leak_probe printf args anchor not found"); sys.exit(1)
    lp = lp.replace(args_anchor,
        "               gc, gap, gpa, gfd, gsg,\n               fb_bytes, fb_bytes >> 20, fb_count);", 1)
    write(LEAKPROBE, lp)
    print("leak_probe.cc instrumented OK")

print("INSTRUMENT DONE")
