# LEAK #2 STEP 1 HISTOGRAM - app-vs-kernel-lifetime of the identity-heap fallback

Box i-0a13d716cee541d70 (m5d.metal, us-east-2, Owner=agent-leak2real).
Base: gh-fork bench/leakhunt @ ac6a389d2 (leak #1 fd fix + probe), apps @ 3f93f43 (grep=1).

## METHOD
Instrumented (hist_instrument.py + hist_refine.py) the identity-heap fallback path in std_malloc:
every app-thread allocation that fell THROUGH the exhausted fork arena to the identity heap is TAGGED
in a BSS hash {va, size, caller RA(1), alloc_as}. At free() it is CLASSIFIED by WHO frees it (reads
only BSS + current_address_space(), never the chunk page -> no cross-AS fault):
  - freed by the SAME AS that allocated it  -> APP-lifetime (backend frees its own heap before exit)
  - freed by a DIFFERENT (cross) AS          -> KERNEL-lifetime (AS0 reaper / RCU / sibling)
  - still live when release_as(alloc_as) runs -> LEAKED at reap (orphaned, the actual per-fork leak)
Bytes bucketed per caller PC. FBHIST lines printed each probe period; symbolized offline (loader.elf +
the postgres ELF). Run: 250-round, 32-conn churn, arena exhausted (arena_used_mb=512), totalCORRUPT=0.

## THE HISTOGRAM (last steady-state block, t=1100, HIST-run4-block.txt)

  total fallback           = 5250.8 MB
  freed same-AS (app-life) = 3744.5 MB  (71.3%)
  freed cross-AS (kern-life)=    2.9 MB  (0.056%)   <-- essentially ZERO kernel-lifetime in the fallback
  leaked at reap           = 1499.9 MB  (28.6%)     <-- the per-fork leak

  OF THE LEAKED BYTES:
    from APP  sites (VA >= 0x100000000000, PostgreSQL) = 1498.1 MB  (99.87%)
    from KERN sites (VA 0x40xxxxxx, OSv kernel)         =    1.9 MB  ( 0.13%)

  ALL cross-AS-freed (kernel-lifetime) bytes (2.9 MB) originate from APP sites, NOT kernel objects.

## PER-SITE (sorted by leaked bytes)
  APP  0x100000b425a8   fb=1085.5MB  freed_app= 318.8MB  freed_kern=0.9MB  LEAKED=763.5MB
  APP  0x100000b427df   fb= 370.1MB  freed_app=   0.0MB  freed_kern=0.0MB  LEAKED=369.7MB
  APP  0x1000009cad8f   fb= 228.3MB  freed_app=   0.0MB  freed_kern=0.0MB  LEAKED=228.1MB
  APP  0x100000b426c3   fb=3485.8MB  freed_app=3350.2MB  freed_kern=2.1MB  LEAKED=133.2MB
  APP  0x1000009cad71   fb=   3.5MB  ...                                    LEAKED=  3.5MB
  KERN 0x40376dae (realloc wrapper) fb=1.8MB            LEAKED=1.8MB   <-- only kernel leak, 0.12%
  KERN 0x4041edbb (strdup)          fb=0.1MB            LEAKED=0.1MB
  KERN 0x4043f75c (operator new)    fb=70.2MB  freed_app=70.2MB  LEAKED=0   <-- all app-lifetime
  KERN 0x403e44f8 (__fdopen)        fb=5.2MB   freed_app= 5.2MB  LEAKED=0
  KERN 0x40376d36 (calloc), 0x40276ea0 (in_getsockaddr) - negligible, all freed same-AS

  The 0x100000b42xxxx / 0x1000009caxxxx PCs are PostgreSQL's own heap allocators (AllocSet /
  MemoryContext family) in a shared object loaded above the postgres base (0x100000000000). They are
  the per-connection app heap (relcache/catcache/memory contexts) - app-lifetime, dies with the backend.
  The 0x40xxxxxx PCs are OSv-kernel libc/mempool WRAPPERS (RA(1) lands on the allocator wrapper, not the
  true caller); their leaked bytes total 1.9 MB (0.13%) and their cross-AS-freed bytes are 0.

## VERDICT (decides the fix)
The leak is APP-LIFETIME. 99.87% of leaked bytes are PostgreSQL's own heap; 0.13% are kernel wrappers.
Kernel-LIFETIME objects (freed cross-AS by RCU/reaper) that reach the fallback = 0.056% of fallback and
0 from kernel sites. This CONFIRMS the DESIGN-RECOMMENDATION finding that all fork-hazard vfs objects
(vnode/dentry/file/fd_table/...) are already kernel_heap_scope'd OFF the arena. => A per-AS overflow
region reclaimed WHOLESALE on reap is SAFE: it holds only app-lifetime objects; no cross-AS-lifetime
kernel object is wholesale-freed (the C3 hazard that crashed the reap-tracker is absent here).

RESIDUAL to close before the fix (STEP 2 part i): the tiny kernel leak (1.9MB, 0.13%) at the realloc/
strdup wrappers. Their true callers are unresolved at RA(1), but they are <=0.13% and freed 0 cross-AS,
so even if they land in the overflow region they are freed same-AS or orphaned app-side - not a UAF.
Still, the overflow-region free() is a NO-OP (BSS range-check, never reads the chunk), so a kernel object
RCU-freed later that happens to be in the region ALSO hits the no-op free -> no double-free by construction.

## NOTE: the histogram instrument itself slows the guest under the 32-way exhausted-arena storm (per-alloc
## tag insert + per-reap 256K sweep). It is MEASUREMENT ONLY and is stripped from the fix. The leak rate
## and the app/kernel split are unaffected by the slowdown (they are per-byte ratios). A cleaner earlier
## run (single-PC key, HIST-run1) gave the same aggregate: fb=48.97GB app=71.0% kern-freed=0.070% leaked=28.9%.
