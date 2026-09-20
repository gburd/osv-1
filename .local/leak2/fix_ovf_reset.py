#!/usr/bin/env python3
# Reset per-AS overflow bump fields when a slot is released/reclaimed, so a
# recycled as_freelist slot never inherits a dead child's (now-unmapped) overflow
# region VA. Idempotent.
f = "core/fork_arena.cc"
s = open(f, encoding="utf-8").read()
if "reset the per-AS overflow bump" in s:
    print("already reset-patched"); raise SystemExit

old = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            g_as_freelists[i].owner.store(nullptr, std::memory_order_release);
            return;"""
new = """            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            // LEAK #2 FIX: reset the per-AS overflow bump. The dead child's
            // overflow region (slot 97) was just unmapped by the page-table
            // teardown; a slot recycled to a NEW AS must NOT inherit the dead VA
            // (using it faults -- the crash this fixes).
            g_as_freelists[i].ovf_next.store(0, std::memory_order_relaxed);
            g_as_freelists[i].ovf_end.store(0, std::memory_order_relaxed);
            g_as_freelists[i].owner.store(nullptr, std::memory_order_release);
            return;"""
assert old in s, "release_as anchor not found"
s = s.replace(old, new, 1)

oldc = """        if (g_as_freelists[i].owner.compare_exchange_strong(
                expect, as, std::memory_order_acq_rel)) {
            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            return &g_as_freelists[i];
        }"""
newc = """        if (g_as_freelists[i].owner.compare_exchange_strong(
                expect, as, std::memory_order_acq_rel)) {
            for (unsigned c = 0; c < num_classes; c++) {
                g_as_freelists[i].heads[c].store(nullptr, std::memory_order_relaxed);
            }
            // LEAK #2 FIX: a freshly-claimed slot starts with no overflow region.
            g_as_freelists[i].ovf_next.store(0, std::memory_order_relaxed);
            g_as_freelists[i].ovf_end.store(0, std::memory_order_relaxed);
            return &g_as_freelists[i];
        }"""
assert oldc in s, "slot_for claim anchor not found"
s = s.replace(oldc, newc, 1)
open(f, "w").write(s)
print("release_as + slot_for ovf-reset applied")
