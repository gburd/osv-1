# LEAK #2 LOCALIZED (2026-09-16) - box i-063d9d27134f102b1 (m5d.metal, us-east-2, Owner=agent-leak2)

## THE EXACT LEAKED ALLOCATION (measured, hypothesis CONFIRMED)
App-thread heap allocations that fall THROUGH the exhausted fork arena to the
IDENTITY kernel heap (core/mempool.cc std_malloc fallback path). Once the fork
arena's 512 MiB global bump pointer (fork_arena::g_bump) is exhausted, EVERY
subsequent forked backend's per-connection heap (relcache/catcache/memory
contexts, ~128 allocs/backend avg ~7.5KB) routes to the identity heap. Identity
heap objects (VA >= 0x400000000000) are shared verbatim across every address
space and are NOT tied to the child AS, so destroy_address_space() on reap never
frees them -> the backend exited but its heap persists -> unreclaimable leak.

## MEASURED RATE (my own run, 300-round pure connect/disconnect churn, bare SELECT 1)
Instrument: added g_app_fallback_bytes/g_app_fallback_count atomics in std_malloc
(incremented ONLY on the app-thread arena-exhausted fallthrough), printed as
fb_bytes/fb_mb/fb_count in the LEAKPROBE line.

CRISP TRANSITION (leak begins EXACTLY when arena exhausts):
  t=5..70   arena_used 1->20 MB, fb_mb=0,   mem_free FLAT ~23445 (arena-backed backends do NOT leak)
  t=70->75  arena 20->512 MB (EXHAUSTS),    fb_mb 0->244, mem_free STARTS dropping
  t=75..195 arena=512 (pinned),             fb_mb 244->17328, mem_free 23169->8902 MONOTONIC

Steady-state interval t=100->190 (well after exhaustion):
  backends reaped:        14,473
  mem_free consumed:      11,142 MB
  => NET LEAK = 0.770 MB per reaped backend   (matches prior hunt's ~0.74)
  gross fallback:         13,325 MB = 0.921 MB/backend over ~128 allocs (avg 7.5KB)
  (gross > net: the fraction the backend frees itself before reap)

## PROOF IT IS THE ARENA-FALLBACK, NOT A THIRD MECHANISM
- Before arena exhaustion, ~350 backends reaped with mem_free FLAT and fb_mb=0.
- The instant arena hits 512, fb_mb and the mem_free drop begin, in lockstep.
- PER-FORK confirmed: this is bare `SELECT 1` connect/disconnect churn (no query
  work, no write txn), so it is not query- or table-dependent.
- Everything else flat: threads 658, child_as 5, arena_as_slots 6, gfdt 29
  (leak #1 fix holds), reaper_pending 0, all g_* maps 5.

## ROOT CAUSE (source)
core/fork_arena.cc: g_bump is a GLOBAL MONOTONIC atomic bump pointer, fetch_add
only, never rewinds. release_as() (called from mmu::destroy_address_space) drops
the dying child's per-AS free-list SLOT but does NOT return the VA the child
carved off g_bump. The child's arena physical pages ARE freed (page-table
teardown of app slot 96), but the VA stays permanently consumed. After ~700
backends' carving the 512 MiB VA is gone; alloc() hits `c+class_size > g_end`,
returns nullptr, and std_malloc falls through to the identity heap for ALL app
allocations of ALL future backends -> the leak.

## FIX (next): reclaim a dead child AS's carved arena VA into a GLOBAL per-class
## reclaim free-list held in kernel BSS (VAs only, no in-arena-page links -> no
## cross-AS COW-coherence problem). alloc checks it before bumping; a reclaimed
## VA handed to a new AS faults a fresh COW-private page on first write. This
## keeps the arena serving every backend so the identity fallback never triggers.
