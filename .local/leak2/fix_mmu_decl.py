#!/usr/bin/env python3
# Fix the mmu.cc reap-hook decl: extern "C" cannot be block-scope. Move it to
# file scope (after the fork_arena include) and keep only the call inside
# destroy_address_space. Idempotent.
f = "core/mmu.cc"
s = open(f, encoding="utf-8").read()

bad = ('    // LEAK #2 STEP 1: bucket any identity-heap fallback still live for this\n'
       '    // AS as LEAKED before the slot is dropped (measurement only).\n'
       '    extern "C" void fbhist_on_reap(void *as);\n'
       '    fbhist_on_reap(as);\n')
good = ('    // LEAK #2 STEP 1: bucket any identity-heap fallback still live for this\n'
        '    // AS as LEAKED before the slot is dropped (measurement only).\n'
        '    fbhist_on_reap(as);\n')
if bad in s:
    s = s.replace(bad, good, 1)
    print("removed block-scope extern decl")

decl = '#if CONF_fork\nextern "C" void fbhist_on_reap(void *as);  // LEAK #2 STEP 1 (core/mempool.cc)\n#endif\n'
if 'extern "C" void fbhist_on_reap(void *as);  // LEAK #2 STEP 1' not in s:
    anchor = "#include <osv/fork_arena.hh>\n"
    assert anchor in s, "fork_arena include anchor missing"
    s = s.replace(anchor, anchor + decl, 1)
    print("added file-scope decl")

open(f, "w").write(s)
print("mmu.cc reap-hook decl fixed")
