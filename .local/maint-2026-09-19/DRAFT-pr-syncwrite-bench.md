# DRAFT PR body - bench/syncwrite-mt (NOT opened; needs your go-ahead)

Branch: gh-fork/bench/syncwrite-mt @ 1cdbe3541 (ONE commit, parent == upstream/master 0e34e4dc2 exactly)

## Why I did not just open it (the judgment call)
It is the only genuinely standalone + merge-clean + validated + unfiled candidate I found this sweep.
Everything checks out mechanically:
- merge-tree vs upstream/master: CLEAN (its parent IS upstream/master, so it applies as a fast-forward).
- touches ONE file, `scripts/bench/zfs-bench.c` (pre-existing on master, blob-identical base) - zero
  kernel code, zero test-manifest change, zero build-system change.
- commit is G-signed (%G?=G), no em-dashes in the message, no perf claims in the message.
- I re-ran the project's own build gate locally: the exact `gcc -std=gnu11 -O2 -fPIC -shared -D__OSV__
  -D_GNU_SOURCE ... -lm` line from `scripts/bench/rebuild-bench.sh` compiles it rc=0, and
  `nm -D | grep -E 'GLIBCXX|CXXABI|__isoc23'` is EMPTY (the hard gate that .so loads in OSv).
- it is the instrument that produced #1511's published measurements (.local/wakelat/ISOLATE-AB-RESULTS.md:
  fixed-10000 27200 op/s vs adaptive 44841 op/s, wake2ent 137us -> 78us, p99 3484 -> 2118), so filing it
  makes #1511's table reproducible by a reviewer.

What I could NOT settle without you: whether the project WANTS another bench workload upstreamed. That is
maintainer taste, not a correctness fact, and the maintainer is offline - so opening it now buys zero
velocity and adds queue noise. Hence: drafted, flagged, not opened. Say the word and it is one command.

## Ready-to-post PR title
bench: durable-write latency isolate with concurrent writers in zfs-bench

## Ready-to-post PR body

The `zfs-bench` harness can measure throughput but not the per-operation cost of a
durable write, which is the quantity a database's commit path actually pays. This adds a
`syncwrite` workload that measures it directly, and a knob to decompose it.

`syncwrite` issues an 8k `pwrite` followed by an `fdatasync` in a loop and records per-op
latency, reporting ops/s with p50 and p99 in microseconds. With a single writer there is
no lock contention to attribute the time to, so the per-op figure is the write-plus-
durability completion path on its own: block submit, the ZFS zio path, and the completion
wakeup that unblocks the caller.

`threads=N` runs N such writers on separate files. That reproduces the commit-completion
serialization a database hits under load without needing a database, and the diagnostic is
whether aggregate throughput scales with N or plateaus. A plateau with the device and the
CPUs both idle points at the completion or wakeup path rather than at bandwidth.

`nofsync=1` drops the `fdatasync`, which separates write-completion cost from durability
cost: if both arms are slow the cost is in write/zio completion, if only the fsync arm is
slow the cost is specifically in the ZIL/flush completion wakeup.

One file, `scripts/bench/zfs-bench.c`, and no change to any kernel or build path. It stays
pure C11 with no libstdc++ dependency, so `scripts/bench/rebuild-bench.sh` still produces a
`.so` OSv can load (the script's `GLIBCXX|CXXABI|__isoc23` gate passes).

This is the instrument behind the measurements quoted in #1511, so it is also what a
reviewer would need to reproduce that table.

## Open command (if you approve)
    cd /tmp/<a worktree at 1cdbe3541>   # or push the branch and use --head
    gh pr create --repo cloudius-systems/osv --base master \
      --head gburd:bench/syncwrite-mt \
      --title 'bench: durable-write latency isolate with concurrent writers in zfs-bench' \
      --body-file <this body, from "The zfs-bench harness" down to "...reproduce that table.">
