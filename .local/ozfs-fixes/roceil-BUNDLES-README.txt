RO SCALING CEILING - fix bundles (box i-02f6e584754a0c39d, m5d.metal, 2026-08-04)

Both commits authored "Greg Burd", leak-clean, committed UNSIGNED (re-sign + push).

1. roceil-mmu-shard.bundle  -> #1458 (integ/pg-fork-zfs)
   base 861be4908 (#1458 tip) .. 42277796f
   commit: "mm: shard the fork shared-anon page registry lock (fix RO scaling ceiling)"
   file: core/mmu.cc (+32/-12). ENTIRELY inside #if CONF_fork -> conf_fork=0 byte-neutral.
   THE fix: eliminates the RO c8-collapse. c32 2930->30953, c48 1509->28051, c64 1006->26313.
   To apply:  git fetch roceil-mmu-shard.bundle mmu-shard-only:X && cherry-pick / rebase onto #1458 tip.

2. roceil-1467-preempt-fix.bundle  -> FOLD INTO #1467 (pr/net-batch-wakeup)
   base 794fe0f0e (#1467 tip) .. fdcad6a18
   commit: "net: defer slow-path RX packets past the batch-wake rcu_read_lock (fix preemptable assert)"
   file: drivers/virtio-net.cc (+18/-1).
   Fixes a REAL crash in #1467: batch path held rcu_read_lock across if_input() ->
   page_fault non-preemptable -> guest aborts on first non-fast-path TCP packet on SMP.
   Without it #1467 cannot be enabled. WITH it, #1467 is correct but shows NO measured
   payoff on the PG RO workload (the ceiling was the mmu lock, not the wake path).

See roceil-FINDINGS.txt for the full profile evidence, A/B tables, and before/after curve.
