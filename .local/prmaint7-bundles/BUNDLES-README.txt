PR-maintenance sweep #7 bundles - RE-SIGN (Greg Burd ED25519 -> G) + push.
All base = upstream/gh-fork master 95f478cb7. All are force-with-lease
UPDATES to an existing PR branch (rebased onto current master, feature-only,
no silent-revert). Use the BRANCH-NAME force-with-lease form:
    git push --force-with-lease gh-fork <new-head>:pr/<branch>
(NEVER delete+recreate; the =branch:sha form trips the hook.)

1. feat-fork.bundle        (#1455 fork base)
   branch: wip/feat-fork
   new head: df4aa2a5e   old remote head: d2cec4b46
   contents: rebased 2 fork commits onto master (dropped merged
     splice/membarrier/sig-dfl/iovcnt via patch-id; resolved signal.cc
     comment + Makefile test-list union) + 1 new doc-only commit
     "fork: document the raw clone-syscall fork path as unsupported"
     (documentation/fork.md - the wkozaczuk syscall-path coverage gap).
   push: git push --force-with-lease gh-fork df4aa2a5e:wip/feat-fork

2. setrlimit.bundle        (#1435 setrlimit - APPROVED, was CONFLICTING)
   branch: pr/setrlimit
   new head: 64e2c792a   old remote head: 83bd22589
   contents: rebased onto master (test-list union only), feature-only.
   push: git push --force-with-lease gh-fork 64e2c792a:pr/setrlimit

3. close-range.bundle      (#1436 close_range - APPROVED, was CONFLICTING)
   branch: pr/close-range
   new head: c5d8e5ade   old remote head: 7c95715fb
   contents: rebased onto master (linux.cc extern union + test-list union),
     feature-only.
   push: git push --force-with-lease gh-fork c5d8e5ade:pr/close-range

4. fs-syscalls.bundle      (#1429 preadv2/pwritev2/renameat2 - APPROVED, was CONFLICTING)
   branch: pr/fs-syscalls
   new head: fd448d42a   old remote head: 298e6bfab
   contents: rebased onto master (linux.cc extern union + test-list union),
     feature-only.
   push: git push --force-with-lease gh-fork fd448d42a:pr/fs-syscalls

All four verified: 0 osv_sigtimedwait reverts, 0 tst-signal-fills/splice/
membarrier/iovcnt deletions, leak-clean commit msgs + diffs.
