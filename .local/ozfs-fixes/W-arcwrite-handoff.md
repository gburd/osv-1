# W-arcwrite / W-lfmutex handoff (from the meh fix agent dae32113)

## W-read = DONE (535791372, pushed)
core/mmu.cc `shared_anon_page_provider` + registry, `pte_shared` tag on teardown,
`anon_vma::update_shared_base()`. Verified 5/5 under KVM -smp 2/4, 0 fork-suite regressions.

## W-arcwrite - IMPORTANT: NOT a "route to identity heap" fix
zfs_kmem_alloc AND kmem_cache_alloc ALREADY route through fork_kernel_heap_push/pop
(identity heap), so the arc_buf_hdr + its zfs_refcount_t ARE coherent across AS.
=> the "VERIFY3S(remove_reference(hdr,hdr),>,0) failed (0>0)" underflow is NOT a
divergent-copy bug. It's likely:
  - a genuine DOUBLE-DROP / ordering issue in arc_write_done, OR
  - an unguarded allocation on the completion CLOSURE / abd path (not the hdr).
Needs a LIVE gdb at arc_write_done under sustained concurrent bulk write to pin
which reference is dropped twice / by whom.

## W-lfmutex (lfmutex.cc unlock:261 owner!=current in taskqueue_thread_loop)
Same neighborhood (ZFS write-completion taskqueue). Likely related to W-arcwrite.

## Repro needs a seeded ZFS pool + SUSTAINED concurrent bulk write
meh couldn't stand this up (too slow, no local NVMe). EC2 metal + local NVMe is
far faster. Uncommitted tst-fork-zfs-arcwrite.cc existed on meh only (not needed).
