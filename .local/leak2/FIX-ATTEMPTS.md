# LEAK #2 FIX attempts (box i-063d9d27134f102b1)

## ATTEMPT 1 (ABANDONED - CRASHED): global BSS VA-reclaim free-list
Design: free() pushes freed chunk base VA to a global per-class BSS ring; alloc()
pops from it before bumping, so freed chunks recycle across address spaces and
the arena never exhausts. Argued safe via per-AS page-table physical isolation.
RESULT: guest ABORTED with an mmap fault the instant the first backend forked
after boot:
  Aborted
  osv::handle_mmap_fault  <- mmu::vm_fault <- page_fault
  (console-run-185045.log, right after "ready to accept connections")
VERDICT: VA-reclaim is UNSAFE in this arena design, exactly as the parent warned.
The arena base mapping (map_anon mmap_fixed|mmap_populate in AS0) is NEVER
munmapped, and a fork child COW-clones the PARENT's slot-96 page tables, not AS0's.
A reclaimed VA carved by dead child A, handed to child B, is not necessarily
present/consistent in B's cloned page tables -> write faults "outside application"
-> abort. The per-AS free-list was deliberately per-AS precisely to never reissue
a VA across the COW boundary. Reverted fork_arena.cc to pristine.

## ATTEMPT 2 (in progress): per-AS COW-private overflow region (SAFE)
Keep g_bump monotonic (never reissue a VA). When the shared arena exhausts,
a child allocates from its OWN per-AS overflow bump region carved in the child's
private app-slot VA (COW-isolated, slots 1..127), which destroy_address_space
already frees on reap. No cross-AS VA reuse, no per-object identity-heap tracking.
The per-AS state hangs off the existing g_as_freelists[256] slot table (already
keyed by address_space*, already reclaimed in release_as). Env-gate
OSV_FORK_ARENA_RECLAIM (default ON; =0 = old exhaust-then-identity-fallback leak).
Validation MUST prove: (a) mem_free flat, (b) fb_bytes stays ~0, (c) ZERO data
corruption across the churn (integ.sh md5+bleed check).
