#!/bin/sh
# Run the preflight against integ/pg-master with the deliberate exclusions DECLARED.
# Every skip below names a REASON, which is the gate's own requirement: "left out on
# purpose" must be distinguishable from "forgot".  Each reason is defensible on its own
# terms, and each was reached by inspecting the conflict, not by convenience.
set -u
TREE="${1:-/home/gburd/ws/osv/.local/rebase/wt-integ}"
[ $# -gt 0 ] && shift

# 1424: a DRAFT PR (crucible distributed block driver), 28 new files, never intended for
#       this integration image; including a draft would misrepresent the stack.
# 1442/1444: the FreeBSD IPv6 forward-port, 100+ files, and its stacked virtio-net
#       offload.  A whole subsystem port, orthogonal to the PG workload, and it collides
#       structurally with our virtio-net multiqueue/inline-RX rework.  Scope decision,
#       not a conflict we should silently resolve.
# 1467: batch per-connection wakeups.  Its target function rx_drain() was REWRITTEN by
#       our multiqueue + inline-RX-IRQ work, so the two are alternative designs for the
#       same code, not additive.  Needs a design decision by the author.
# 1503: per-chain dentry hash locks.  A structural redesign of the locking our CONF_fork
#       kernel-heap scopings are threaded through (9 conflicts in vfs_dentry.cc).  #1502,
#       the AB-BA fix it stacks on, IS present.
# 1455/1456/1458/1475: the fork series itself and its tracking draft; present as the fork
#       stack by construction (this branch IS that work), so the PR-diff test is circular.
# 1492/1478: superseded IMPLEMENTATION VARIANTS of fixes already present in a better
#       form.  See RESULT.md for the line-by-line argument in each case.
# 1493: PRESENT except 3 lines that are the RDRAND-ONLY variant it shares with #1492
#       (drng_read / "if (rdrand)").  We deliberately carry the SUPERSET on the x86 leg
#       (rdrand OR rdseed via hw_rng_fill, needed because native Nitro reports rdrand
#       false but offers rdseed) while taking #1493's aarch64 RNDR leg verbatim.  So the
#       3 "missing" lines are exactly the ones we intend to be missing.
# 1455: the fork() series itself.  This branch IS that work, so testing it by PR diff is
#       circular; the 15% shortfall is its own tst-fork.cc/tst-execve.cc probe scaffolding
#       and CONF_fork-off SKIP paths, not kernel code.
# WRAPPER ARGUMENT BUG, found 2026-09-22 by bench24 and fixed here.
# The exec line used to read: exec .../bench-preflight.sh "$TREE"
# so `preflight-integ.sh <tree> --build-log X --runtime-proof Y` SILENTLY DROPPED
# both evidence flags and still printed PASS.  The two checks that exist to catch
# a silently skipped patch and an unproven lever were therefore unreachable
# THROUGH THIS WRAPPER, which is the only way anyone invokes them here -- the
# inner script had been negative-tested, but only by calling it directly.
# Exactly the documented pattern: a convenience wrapper quietly became a
# correctness assumption.  Fixed by `shift`-ing $TREE and forwarding "$@".
#
# AND A SECOND BUG THE FIRST FIX CAUSED, recorded because it is instructive:
# these comments were initially placed BETWEEN the trailing `\` of
# BENCH_PR_REASONS and the `exec`, which severs the line continuation.  The
# env-var assignments then stopped being a prefix to exec, so BENCH_SKIP_PRS and
# BENCH_PR_REASONS were NEVER PASSED, and all 9 declared exclusions came back as
# FAIL (8 UNDETERMINED + #1424 ABSENT).  A comment is not inert inside a
# backslash continuation.  Comments must live ABOVE the assignment block.
BENCH_SKIP_PRS="1424 1442 1444 1467 1503 1492 1478 1493 1455" \
BENCH_PR_REASONS="1424:draft-crucible-driver-not-for-this-image \
1442:ipv6-subsystem-port-100-files-orthogonal-and-collides-with-our-virtio-net-rework \
1444:stacked-on-1442 \
1467:rx_drain-rewritten-by-our-multiqueue-inline-rx-alternative-design-not-additive \
1503:per-chain-dentry-lock-redesign-vs-our-fork-scopings-1502-base-fix-IS-present \
1492:superseded-ours-covers-RDRAND-or-RDSEED-1492-is-RDRAND-only \
1478:superseded-our-inline-cv_timedwait_hires-is-semantically-identical-see-RESULT.md \
1493:aarch64-RNDR-leg-taken-x86-leg-deliberately-superset-rdrand-OR-rdseed \
1455:the-fork-series-itself-this-branch-IS-that-work-PR-diff-test-is-circular" \
exec /home/gburd/ws/osv/.local/bench-preflight.sh "$TREE" "$@"
