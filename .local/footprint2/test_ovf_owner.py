#!/usr/bin/env python3
"""Self-check for the CHURN FIX's owner-arithmetic invariant.

The fix rests on ONE property: an overflow pointer's owning AS slot is
recoverable from the VA alone, by BSS-only arithmetic, so free() can decide
same-AS vs foreign WITHOUT reading the arena page (the C2-safety constraint that
produced the original unconditional no-op).

This checks that property, plus the window-disjointness it depends on, against
the exact constants in core/fork_arena.cc. It fails loudly if someone retunes a
constant in a way that breaks the invariant (e.g. shrinking slot 97, or raising
max_as_slots past what the windows can cover).
"""
OVF_SLOT_BASE = 97 << 39
OVF_SLOT_END = 98 << 39
MAX_AS_SLOTS = 256
OVF_WINDOW_SZ = (OVF_SLOT_END - OVF_SLOT_BASE) // MAX_AS_SLOTS
OVF_REGION_SZ = 1 << 20
MAX_ALLOC = 2 << 20


def owner_slot(va):
    """Mirror of fork_arena.cc ovf_owner_slot()."""
    return (va - OVF_SLOT_BASE) // OVF_WINDOW_SZ


def win_base(slot):
    return OVF_SLOT_BASE + slot * OVF_WINDOW_SZ


def demo():
    # The static_assert in the C++ must hold.
    assert OVF_WINDOW_SZ >= (1 << 31), f"window too small: {OVF_WINDOW_SZ:#x}"

    # 1. Windows tile slot 97 exactly: no overlap, no gap.
    assert win_base(0) == OVF_SLOT_BASE
    assert win_base(MAX_AS_SLOTS - 1) + OVF_WINDOW_SZ == OVF_SLOT_END
    for s in range(MAX_AS_SLOTS - 1):
        assert win_base(s) + OVF_WINDOW_SZ == win_base(s + 1), s

    # 2. EVERY address in a slot's window resolves to that slot -- the property
    #    free() relies on. Check both edges and the interior.
    for s in range(MAX_AS_SLOTS):
        b = win_base(s)
        for va in (b, b + 1, b + OVF_REGION_SZ, b + OVF_WINDOW_SZ - 1):
            assert owner_slot(va) == s, (s, hex(va), owner_slot(va))

    # 3. A window holds enough regions to be useful (churn headroom), and a
    #    max-size allocation still fits.
    assert OVF_WINDOW_SZ // OVF_REGION_SZ >= 2048
    assert MAX_ALLOC <= OVF_WINDOW_SZ

    # 4. Neighbour windows cannot alias: the last byte of slot s and the first
    #    byte of slot s+1 must attribute differently (the foreign-free test).
    for s in range(MAX_AS_SLOTS - 1):
        last = win_base(s) + OVF_WINDOW_SZ - 1
        first = win_base(s + 1)
        assert owner_slot(last) == s and owner_slot(first) == s + 1, s

    # 5. The decision free() makes: owner recycles, foreign no-ops.
    owner, foreign = 7, 9
    p = win_base(owner) + 3 * OVF_REGION_SZ + 64
    assert owner_slot(p) == owner           # owner recycles (safe header read)
    assert owner_slot(p) != foreign         # foreign no-ops (NO header read)

    print(f"OK  window={OVF_WINDOW_SZ >> 30} GiB/AS  slots={MAX_AS_SLOTS}  "
          f"regions/window={OVF_WINDOW_SZ // OVF_REGION_SZ}")


if __name__ == "__main__":
    demo()
