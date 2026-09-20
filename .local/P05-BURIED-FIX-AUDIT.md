# P0.5 buried-fix audit: complete, and the honest answer is "only one"

Question: #1492 (the x86 RDRAND early-read fix) sat unshipped inside fork
mega-commit `858dd78f2`/`9108df4b5` purely because it was swept into a large
feature commit. Is that pattern systemic? Are there more extractable generic
fixes hiding in our big commits?

Answer: **No. #1492 was the only one.** Audited and closed 2026-09-05.

## Method

1. Ranked all 129 commits on v26 by insertions to find the mega-commits.
2. For each fork-titled commit, listed every non-test, non-Makefile file and
   flagged those whose added lines contain NO `CONF_fork` / `fork_arena` /
   `osv::fork` guard - i.e. candidates that might be independent of fork.
3. Read each candidate hunk to judge whether it is genuinely independent.
4. Swept the whole stack for standalone commits (non-fork/zfs/net titled) that
   touch `drivers/` or `libc/`, to catch independent fixes hiding anywhere.

## Findings per candidate

| File / commit | Verdict |
|---|---|
| `drivers/random.cc` in 9108df4b5 | **EXTRACTED as #1492.** Self-contained; its own comment says "independent of fork" |
| `core/rcu.cc` in 9108df4b5 | Correctly fork-coupled: `#if CONF_fork`, about a fork-child's on-stack wait_record being unmapped in AS0 |
| `core/epoll.cc` in 9108df4b5 | Fork-coupled (cross-AS epoll container coherence) |
| `core/waitqueue.cc` + `include/osv/wait_record.hh` in d98a88480 | NOT independent fixes: mechanical refactors indirecting `_wr` through `record()` to support the fork coherence work |
| `arch/*/fork.cc`, `include/osv/fork.hh`, `conf/kconfig/threads`, `libc/process/fork.cc`, `documentation/fork.md` | Fork implementation by nature; flagged only because a fork file needs no fork guard |
| `libc/signal.cc`, `include/osv/mmu-defs.hh`, `libc/process/execve.cc` | Part of the fork semantics (per-process dispositions, COW address space, exec teardown) |

## The standalone commits are all already in PRs

The whole-stack sweep found the expected set, each already represented upstream or
in an open PR: nvme queue depth / coalescing / MSI-X cap (#1479, #1481, #1465),
pagecache + `file::sync` (#1483), callout (#1486), ARC patches 0030/0031/0032
(#1487), ena RSS (#1470), ld-musl soname (merged), taskq_wait (#1423 family).
Nothing orphaned.

## Conclusion

The mega-commits are large because the fork work genuinely spans many files with
real cross-file coupling, not because unrelated fixes were dumped into them.
#1492 was a single lapse, now corrected.

The standing rule stays worth keeping - audit large feature commits for
self-contained hunks - but this stack is clean, and no further extraction work is
warranted. Do not spend more time here.
