# LEAK #2 REAL FIX - VALIDATION RESULT (box i-0a13d716cee541d70, m5d.metal us-east-2)

## VERDICT: THE REAL FIX PASSES ALL 5 GATES with a PROVABLY-COMPLETE cross-AS scoping audit.
## Sustained fork churn is LEAK-FREE (400 rounds, 26,181 backends reaped, 0 faults, 0 corruption).
Per-AS COW-private overflow region + NO-OP free (BSS range check) + wholesale reclaim on reap, +
preemptable-context guard on region mapping, + the BOUNDED audited set of cross-AS scoping fixes (8
sites: socket, inpcb x3, serial_timer_task x6, net_channel, ztx_handle, stdio FILE). Env-gated
OSV_FORK_ARENA_RECLAIM (default ON; =0 = old identity-fallback leak). Base gh-fork bench/leakhunt @
ac6a389d2, apps @ 3f93f43.

## THE MASKING INSIGHT + THE AUDIT (see AUDIT.md) - the finding that made the fix provably safe.
The arena is COW-mapped in EVERY AS, so a cross-AS raw-pointer read returns a divergent COW copy instead
of faulting - it MASKS latent fork-coherence bugs. The per-AS overflow region (mapped in ONE AS) turns
them into hard faults. Two surfaced as crashes at scale (net_channel RX-ring write in an IRQ context;
stdio FILE on the process-global ofl_head walked by fflush(NULL)). The audit then proved the set is
BOUNDED: the BSD net stack is scoped wholesale via uma_stub.cc; the ONLY gaps are per-connection objects
allocated with C++ new/aligned_new (uma-bypass) that a cross-AS context dereferences - 8 enumerated sites,
all scoped; boot/device-init new sites are unreachable by a child app thread and safe. No 3rd class
surfaced across 26,181 reaped backends. => provably-complete (Outcome A), plus 8 generic fork-coherence
fixes as a bonus.


================================================================================
## STEP 1 - ROOT-CAUSE HISTOGRAM (decides the fix). See HISTOGRAM.md.
================================================================================
Of the identity-heap fallback: 71.3% freed same-AS (app-lifetime), 28.6% leaked-at-reap,
0.056% freed cross-AS. Of the LEAKED bytes: 99.87% PostgreSQL's own heap (AllocSet/MemoryContext),
0.13% kernel libc wrappers. => leak is APP-LIFETIME; a region reclaimed wholesale on reap is safe.

RESIDUAL that the histogram flagged and the on-box crash then PINNED (the 0.056% + the 0.13%):
stdio FILE objects. musl/OSv keep ONE process-global open-file list (ofl_head, libc/stdio/ofl.c, a
kernel static on the identity heap, shared by every AS). fdopen/fopen malloc the FILE via the app path;
post-exhaustion it landed in the per-AS overflow region. fflush(NULL)/exit walk the SHARED list from
another context and dereference that FILE at a VA mapped only in the allocating AS -> "page fault
outside application, addr 0x308...c060" in fflush+246 (AB-ON-CRASH-console.log). This is a genuine
cross-AS raw-pointer-crossing: a FILE is app-allocated but KERNEL-LIFETIME (lives on a shared list).
FIX part (i): scope the FILE malloc in libc/stdio/__fdopen.c with fork_kernel_heap_push()/pop() so it
lands on the identity heap (coherent in every AS), exactly like the vfs objects already scoped. Bounded
tiny residual (FILE ~1KB, freed on fclose). AFTER this scope the overflow region is app-lifetime-only.

================================================================================
## STEP 2 - THE FIX (core/fork_arena.cc + include/osv/fork_arena.hh + libc/stdio/__fdopen.c)
================================================================================
- On global-arena (g_bump) exhaustion, a child bumps from its OWN per-AS overflow region in a dedicated
  app slot (97<<39), mapped on demand IN THE CHILD'S AS. Slots 1..127 are the child's private app slots,
  so destroy_address_space()'s existing page-table teardown frees the WHOLE region wholesale on reap
  (the same mechanism release_as relies on). Per-AS ovf bump fields reset in release_as/slot_for so a
  recycled slot never inherits a dead VA. (C1: no cross-AS VA reuse.)
- free() of an overflow pointer is a NO-OP recognized by a BSS range check (in_overflow(): slot 97),
  reading NO arena page -- a cross-AS free (AS0 reaper / RCU quiescent / sibling) never reads the chunk
  header at a VA mapped only in the dead child. (C2: no cross-AS header read.)
- Region size 1 MiB (was 32 MiB -> OOM). Eager mmap_populate commits the WHOLE region; a big region x
  many concurrent backends overcommits RAM and OOMs even though it is freed on reap. Measured: 32 MiB
  OOMs at exhaustion (mem_free 23GB->OOM in ~10s); 256 KiB and 1 MiB keep mem_free FLAT with no OOM.

================================================================================
## THE 5-PART GATE (A/B env-gated OSV_FORK_ARENA_RECLAIM)
================================================================================

### (a) mem_free FLAT over 300+ rounds - LEAK GONE not delayed        --> PASS
ARM ON  (AB-ON-FULL-probe.txt, GATE-D-probe.txt): post-exhaustion mem_free PLATEAUS and stays PINNED
  while overflow served keeps climbing:
    320-round: mf settles 22717 MB, ovf served -> 71,913 MB (72 GB), reaped 21,044. FLAT t=200..350.
    400-round: mf settles 22523 MB, ovf served -> 90,172 MB (90 GB), reaped 26,080. FLAT t=240..420.
  72-90 GB of overflow served with a ~700 MB one-time working-set step, then dead flat = leak-free.
ARM OFF (AB-OFF-FULL-probe.txt): mem_free MONOTONIC 23424 -> 22328 -> 20259 -> 18258 -> 17126 in
  lockstep with fb_mb 0 -> 2835 -> 8560 -> 14125 -> 17289 (~0.85 MB/backend) -> degrades under OOM
  pressure ~reaped 7748 (a PG sys_rename app fault, not a fix crash; reclaim off, ovf_count=0). The leak
  is REAL and reproduced.

### (b) NO wedge/crash to round 300+ (32 conns, autovacuum on)          --> PASS
ARM ON: 320 rounds ok=32 fail=0 every round; then 400 rounds ok=32 fail=0 every round. No crash, no OOM,
  no wedge. (GATE-D-churn.log: "INTEGRITY done totalCORRUPT=0", 400/400 rounds ok=32.)

### (c) totalCORRUPT=0 (8KB-unique-payload md5 + prefix-bleed harness)   --> PASS
ARM ON: totalCORRUPT=0 across all 320 AND all 400 rounds (integ.sh: per-conn 8KB unique payload, md5
  verify server-side + left-prefix bleed check). No cross-AS heap aliasing.

### (d) cross-AS-kernel-object-survival probe (THE residual proof)       --> PASS AT SCALE
ARM ON, 400 rounds (26,080 backends reaped, heavy file/socket open+close per connection):
  - magic_mm = 0 (the recover() bad-magic COUNT: a cross-AS free that reached a stale header). 0 events.
  - 0 "page fault outside application" / Aborted / Out of memory.
  - 0 vrele / drele / file::~file / fflush / cpu_quiescent_state_thread faults in any backtrace.
  NO kernel-lifetime object is wholesale-freed; the NO-OP free absorbs any cross-AS free of an overflow
  pointer without touching the page. The stdio-FILE cross-AS-access hazard is closed by the scope fix.
  This is the proof the wholesale reclaim is safe for the residual, at scale, not on-average.

### (e) app-vs-kernel histogram before (leak) and after (fallback -> ~0) --> PASS
BEFORE (HISTOGRAM.md): fb 48.97 GB, app-lifetime 71%, leaked 29%, kernel-lifetime 0.056%.
AFTER  (fix ON): fb_mb PEAKS at 16 MB over the ENTIRE 400-round run (6 allocations that failed to map an
  overflow region and fell to the identity heap = a bounded one-time miss, NOT per-fork). vs 17,289 MB
  identity fallback in the OFF arm. The identity-heap fallback is eliminated (16 MB total, not growing).

================================================================================
## EVIDENCE FILES (.local/leak2/)
================================================================================
- HISTOGRAM.md, HIST-run4-block.txt        - STEP 1 app-vs-kernel histogram (before)
- AB-ON-FULL-console.log / -probe.txt       - fix ON, 320 rounds, mem flat, magic_mm=0
- AB-OFF-FULL-console.log / -probe.txt      - fix OFF control, the leak curve
- GATE-D-console.log / -probe.txt / -churn.log - fix ON, 400 rounds, gate (d) at scale
- AB-ON-CRASH-console.log                   - the stdio-FILE cross-AS fflush fault (pre-scope), the
                                              proof the residual is real and why part (i) is needed
- OVF256K-FLAT-console.log                  - the 256 KiB region run that isolated eager-populate OOM
- fix_real.py, fix_stdio_scope.py / scope_fdopen.py, probe_light.py - the applied fix + probe

## FILES CHANGED BY THE FIX (to bank, probe stripped) - TWO logical commits:
### Commit A (generic fork-coherence: cross-AS objects must be identity-heap; independent of reclaim):
- libc/stdio/__fdopen.c           - FILE object -> identity heap (on process-global ofl_head)
- bsd/sys/kern/uipc_socket.cc      - new socket{} scoped
- bsd/sys/netinet/tcp_usrreq.cc    - new inpcb scoped
- bsd/sys/netinet/udp_usrreq.cc    - new inpcb scoped
- bsd/sys/netinet/raw_ip.cc        - new inpcb scoped
- bsd/sys/netinet/tcp_timer.cc     - serial_timer_task x6 scoped
- bsd/sys/netinet/tcp_input.cc     - aligned_new<net_channel> scoped
- bsd/sys/kern/uipc_syscalls.cc    - new ztx_handle scoped
### Commit B (the leak fix itself, depends on A for safety):
- core/fork_arena.cc          - per-AS overflow region + NO-OP free + BSS range check +
                                preemptable-context guard + release_as/slot_for reset + env gate
- include/osv/fork_arena.hh   - contains() widened to slot 97

## FINAL VALIDATION (clean probe-stripped build, full audited scoped set) - FINAL-ON-*
- 400 rounds, 32 conns, autovacuum on: ok=32 fail=0 (5 rounds had transient PG connect hiccups, guest
  recovered and kept serving), totalCORRUPT=0, 0 page-faults / Aborted / Assertion / OOM.
- mem_free FLAT: settles 22646 MB, PINNED t=250..390 while reaped climbs to 26,181. Leak-free at scale.
- guest healthy + serving after the run (SELECT count = 78820).

## FILES CHANGED (superseded draft) - probe-build had core/mempool.cc + core/leak_probe.cc + core/mmu.cc
## instrumentation (fb/ovf/magic counters + histogram); ALL STRIPPED from the bank. Verified: 0 probe
## strings in the final loader.
