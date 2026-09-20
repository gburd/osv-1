#!/usr/bin/env python3
# Refine STEP 1: RA(0) resolved to malloc itself (std_malloc is a distinct
# function, so RA(0) at the tag point == malloc's return site). OSv builds with
# -fno-omit-frame-pointer, so deeper frames are reliable. Capture RA(1)/RA(2)/
# RA(3) (malloc's caller and up) and key the histogram on RA(1) = the real
# allocation site; also record RA(2)/RA(3) so a generic wrapper (palloc) can be
# walked past offline. Idempotent-ish (expects hist_instrument.py already applied).
f = "core/mempool.cc"
s = open(f, encoding="utf-8").read()

# 1. capture three frames instead of one at the fallback point.
old = "        fb_took_fallback = true;\n        fb_caller = reinterpret_cast<uintptr_t>(__builtin_return_address(0));"
new = ("        fb_took_fallback = true;\n"
       "        // RA(0)==malloc; the real caller chain is RA(1)/RA(2)/RA(3)\n"
       "        // (frame pointers are kept: -fno-omit-frame-pointer).\n"
       "        fb_caller  = reinterpret_cast<uintptr_t>(__builtin_return_address(1));\n"
       "        fb_caller2 = reinterpret_cast<uintptr_t>(__builtin_return_address(2));\n"
       "        fb_caller3 = reinterpret_cast<uintptr_t>(__builtin_return_address(3));")
assert old in s, "fallback capture anchor not found (run hist_instrument.py first)"
s = s.replace(old, new, 1)

# 2. declare the extra locals.
old2 = ("#if CONF_fork\n"
        "    bool fb_took_fallback = false;\n"
        "    uintptr_t fb_caller = 0;\n"
        "#endif\n")
new2 = ("#if CONF_fork\n"
        "    bool fb_took_fallback = false;\n"
        "    uintptr_t fb_caller = 0, fb_caller2 = 0, fb_caller3 = 0;\n"
        "#endif\n")
assert old2 in s, "std_malloc locals anchor not found"
s = s.replace(old2, new2, 1)

# 3. pass all three to on_fallback.
old3 = ("    if (fb_took_fallback && ret) {\n"
        "        fbhist::on_fallback(ret, size, fb_caller);\n"
        "    }")
new3 = ("    if (fb_took_fallback && ret) {\n"
        "        fbhist::on_fallback(ret, size, fb_caller, fb_caller2, fb_caller3);\n"
        "    }")
assert old3 in s, "on_fallback call anchor not found"
s = s.replace(old3, new3, 1)

# 4. extend the tag struct + on_fallback signature + site to hold caller2/3.
old4 = ("struct tag {\n"
        "    std::atomic<uintptr_t> va{0};    // user pointer, 0 == empty slot\n"
        "    unsigned long          size{0};\n"
        "    uintptr_t              caller{0};// return address that requested it\n"
        "    void*                  alloc_as{nullptr};\n"
        "};")
new4 = ("struct tag {\n"
        "    std::atomic<uintptr_t> va{0};    // user pointer, 0 == empty slot\n"
        "    unsigned long          size{0};\n"
        "    uintptr_t              caller{0};// RA(1): direct caller of malloc\n"
        "    uintptr_t              caller2{0}, caller3{0};  // RA(2)/RA(3)\n"
        "    void*                  alloc_as{nullptr};\n"
        "};")
assert old4 in s, "tag struct anchor not found"
s = s.replace(old4, new4, 1)

# site: add caller2/caller3 sample (last-writer-wins; for symbolizing the chain).
old5 = ("struct site {\n"
        "    std::atomic<uintptr_t>     pc{0};        // 0 == empty\n")
new5 = ("struct site {\n"
        "    std::atomic<uintptr_t>     pc{0};        // 0 == empty (RA(1))\n"
        "    std::atomic<uintptr_t>     pc2{0}, pc3{0}; // RA(2)/RA(3) sample\n")
assert old5 in s, "site struct anchor not found"
s = s.replace(old5, new5, 1)

# on_fallback signature + body: accept caller2/3, sample into the site.
old6 = ("inline void on_fallback(void *p, unsigned long size, uintptr_t caller) {\n"
        "    g_fb_bytes.fetch_add(size, std::memory_order_relaxed);\n"
        "    g_fb_count.fetch_add(1, std::memory_order_relaxed);\n"
        "    site *st = site_for(caller);\n"
        "    st->fb_bytes.fetch_add(size, std::memory_order_relaxed);\n"
        "    st->fb_count.fetch_add(1, std::memory_order_relaxed);")
new6 = ("inline void on_fallback(void *p, unsigned long size, uintptr_t caller,\n"
        "                        uintptr_t caller2, uintptr_t caller3) {\n"
        "    g_fb_bytes.fetch_add(size, std::memory_order_relaxed);\n"
        "    g_fb_count.fetch_add(1, std::memory_order_relaxed);\n"
        "    site *st = site_for(caller);\n"
        "    st->pc2.store(caller2, std::memory_order_relaxed);\n"
        "    st->pc3.store(caller3, std::memory_order_relaxed);\n"
        "    st->fb_bytes.fetch_add(size, std::memory_order_relaxed);\n"
        "    st->fb_count.fetch_add(1, std::memory_order_relaxed);")
assert old6 in s, "on_fallback body anchor not found"
s = s.replace(old6, new6, 1)

# store caller2/3 in the tag on insert.
old7 = ("            g_tags[s].size = size;\n"
        "            g_tags[s].caller = caller;\n"
        "            g_tags[s].alloc_as = mmu::current_address_space();")
new7 = ("            g_tags[s].size = size;\n"
        "            g_tags[s].caller = caller;\n"
        "            g_tags[s].caller2 = caller2;\n"
        "            g_tags[s].caller3 = caller3;\n"
        "            g_tags[s].alloc_as = mmu::current_address_space();")
assert old7 in s, "tag insert anchor not found"
s = s.replace(old7, new7, 1)

# 5. dump pc2/pc3 too.
old8 = ("extern \"C\" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,\n"
        "                                unsigned long *app_b, unsigned long *kern_b,\n"
        "                                unsigned long *leak_b, unsigned max) {\n"
        "    unsigned n = 0;\n"
        "    for (unsigned i = 0; i < 512 && n < max; i++) {\n"
        "        uintptr_t p = fbhist::g_sites[i].pc.load(std::memory_order_relaxed);\n"
        "        if (!p) continue;\n"
        "        pc[n]     = p;\n")
new8 = ("extern \"C\" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,\n"
        "                                unsigned long *app_b, unsigned long *kern_b,\n"
        "                                unsigned long *leak_b, unsigned max,\n"
        "                                uintptr_t *pc2, uintptr_t *pc3) {\n"
        "    unsigned n = 0;\n"
        "    for (unsigned i = 0; i < 512 && n < max; i++) {\n"
        "        uintptr_t p = fbhist::g_sites[i].pc.load(std::memory_order_relaxed);\n"
        "        if (!p) continue;\n"
        "        pc[n]     = p;\n"
        "        if (pc2) pc2[n] = fbhist::g_sites[i].pc2.load(std::memory_order_relaxed);\n"
        "        if (pc3) pc3[n] = fbhist::g_sites[i].pc3.load(std::memory_order_relaxed);\n")
assert old8 in s, "fbhist_dump anchor not found"
s = s.replace(old8, new8, 1)

open(f, "w").write(s)
print("mempool.cc caller-chain refinement applied")

# 6. leak_probe.cc: pass pc2/pc3 buffers and print them.
lp = "core/leak_probe.cc"
t = open(lp, encoding="utf-8").read()
old9 = ('extern "C" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,\n'
        '                                unsigned long *app_b, unsigned long *kern_b,\n'
        '                                unsigned long *leak_b, unsigned max);')
new9 = ('extern "C" unsigned fbhist_dump(uintptr_t *pc, unsigned long *fb_b,\n'
        '                                unsigned long *app_b, unsigned long *kern_b,\n'
        '                                unsigned long *leak_b, unsigned max,\n'
        '                                uintptr_t *pc2, uintptr_t *pc3);')
assert old9 in t, "leak_probe fbhist_dump decl anchor not found"
t = t.replace(old9, new9, 1)

old10 = ("            uintptr_t pc[64]; unsigned long fbb[64], appb[64], kernb[64], leakb[64];\n"
         "            unsigned n = fbhist_dump(pc, fbb, appb, kernb, leakb, 64);\n"
         "            for (unsigned i = 0; i < n; i++) {\n"
         "                if (fbb[i] == 0) continue;\n"
         "                printf(\"FBHIST t=%lu pc=%p fb_b=%lu app_b=%lu kern_b=%lu leak_b=%lu\\n\",\n"
         "                       t, (void*)pc[i], fbb[i], appb[i], kernb[i], leakb[i]);\n"
         "            }")
new10 = ("            uintptr_t pc[64], pc2[64], pc3[64];\n"
         "            unsigned long fbb[64], appb[64], kernb[64], leakb[64];\n"
         "            unsigned n = fbhist_dump(pc, fbb, appb, kernb, leakb, 64, pc2, pc3);\n"
         "            for (unsigned i = 0; i < n; i++) {\n"
         "                if (fbb[i] == 0) continue;\n"
         "                printf(\"FBHIST t=%lu pc=%p pc2=%p pc3=%p fb_b=%lu app_b=%lu kern_b=%lu leak_b=%lu\\n\",\n"
         "                       t, (void*)pc[i], (void*)pc2[i], (void*)pc3[i],\n"
         "                       fbb[i], appb[i], kernb[i], leakb[i]);\n"
         "            }")
assert old10 in t, "leak_probe FBHIST print anchor not found"
t = t.replace(old10, new10, 1)
open(lp, "w").write(t)
print("leak_probe.cc caller-chain print applied")
print("REFINE DONE")
