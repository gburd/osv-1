#!/bin/sh
# bench-base-gate.sh -- refuse to benchmark a PG-at-scale base that is missing a
# required OSv-side fix.  Run this against the OSv SOURCE TREE the image will be
# built from (pass the tree root as $1, default: cwd).  Exits non-zero and names
# the missing fix + PR if any required marker is absent, so a benchmark run
# aborts before spending a box instead of wedging mid-sweep.
#
# WHY THIS EXISTS: a benchmark base was once assembled from "the fixes I was
# actively working" plus whatever the parent commit happened to carry, and it
# silently omitted PR #1502 (the dentry AB-BA lock-order fix).  That fix removes
# a DEADLOCK that wedges the guest at VU32, so the run could never complete the
# scaling sweep -- wasted hours and money.  This gate makes the fix set a
# checklist, not an act of memory.
#
# Each row: PR  file  grep-marker  min-count  why.  A base is REQUIRED to carry
# every row below.  Optional/situational fixes (#1503 per-chain locks, #1506 ARC
# env knob) are intentionally NOT gated -- see the notes at the bottom.
#
# ANCESTRY: content markers alone are NOT enough.  A base was benchmarked for
# weeks while sitting 24 commits BEHIND upstream/master, forked before the commit
# that restructured modules/open_zfs (0e34e4dc2).  Every content marker passed,
# because the markers only ask "is this fix present", never "is this base current".
# Consequences: the run was described as the projected-merged future when it was
# really the fork stack as of an older fork point; and a fix whose upstream form
# edits a file that only exists after the restructure could not be applied at all.
# So the gate now also asserts the base is a DESCENDANT of upstream/master.
# Override with BENCH_ALLOW_STALE_BASE=1 when an old base is deliberate, e.g. when
# re-measuring an earlier result on its original base for a single-variable A/B.

TREE="${1:-.}"
fail=0

check() {
    pr="$1"; file="$2"; marker="$3"; min="$4"; why="$5"
    if [ ! -f "$TREE/$file" ]; then
        echo "GATE FAIL [$pr] $file MISSING from tree ($why)" >&2
        fail=1
        return
    fi
    n=$(grep -c -F -- "$marker" "$TREE/$file" 2>/dev/null)
    [ -z "$n" ] && n=0
    if [ "$n" -lt "$min" ]; then
        echo "GATE FAIL [$pr] '$marker' in $file: found $n, need >=$min ($why)" >&2
        fail=1
    else
        echo "  ok [$pr] $marker ($n)"
    fi
}

echo "bench-base-gate: verifying required OSv-side fixes in $TREE"

check "#1504"  "arch/x64/arch-tls.hh"        "stack_guard"                 3 "PG must survive fork (psABI TCB guards)"
check "#1505"  "bsd/porting/netport1.cc"     "openzfs_cv_timedwait_hires"  1 "ZIL commit timeout correctness"
check "#1472"  "core/sched.cc"               "try_pull_from_busiest"       1 "high-VU scaling (idle-CPU pull)"
check "#1472"  "core/sched.cc"               "wake_pull_enabled = true"    1 "scaling on by default"
check "#1507"  "core/pagecache.cc"           "write_cache.empty"           1 "per-fsync O(filesize) writeback tax"
check "#1502"  "fs/vfs/vfs_dentry.cc"        "vfs_dentry_hash_lock_held"   1 "VU32 wedge: dentry AB-BA deadlock CAPS THE SWEEP"
check "#1509"  "drivers/virtio-blk.cc"       "req_done_q"                  1 "WAL-commit-completion serialization (per-queue completion; set OSV_BLK_MQ_COMPLETE=1)"
check "FORK"   "core/mmu.cc"                 "OSV_FORK_RANGE_BS"           2 "fork/connect latency (range binary-search)"
check "FORK"   "core/mmu.cc"                 "OSV_FORK_LARGE_SHARE"        2 "fork/connect latency (large-page share)"

# Optional/situational -- reported but NOT gated:
#   #1503 per-chain dentry locks: measured throughput-null; does NOT fix the
#         deadlock (a per-bucket lock still inverts against vn_lock).  Include
#         only when specifically A/B-testing contention.
#   #1506 OSV_ZFS_ARC_MAX: needed only when matching OSv's ARC to another
#         system's cap FROM the OSv side; can equally be matched on the other
#         side.  Not a correctness/scaling fix.
for opt_marker in dentry_chain_lock OSV_ZFS_ARC_MAX; do
    if grep -rqs -F -- "$opt_marker" "$TREE/fs/vfs/vfs_dentry.cc" "$TREE/core/pagecache.cc" 2>/dev/null; then
        echo "  note: optional marker '$opt_marker' present"
    fi
done

# Ancestry: is the base actually current with upstream/master?  A content-only
# gate passed for weeks on a base 24 commits behind master (fork point cb8c7205b,
# before the modules/open_zfs restructure in 0e34e4dc2).
if git -C "$TREE" rev-parse --git-dir >/dev/null 2>&1; then
    if git -C "$TREE" rev-parse --verify -q upstream/master >/dev/null 2>&1; then
        if git -C "$TREE" merge-base --is-ancestor upstream/master HEAD 2>/dev/null; then
            echo "  ok [ancestry] base contains upstream/master"
        else
            behind=$(git -C "$TREE" rev-list --count "$(git -C "$TREE" merge-base upstream/master HEAD)"..upstream/master 2>/dev/null)
            if [ "${BENCH_ALLOW_STALE_BASE:-0}" = "1" ]; then
                echo "  note [ancestry] base is ${behind:-?} commits behind upstream/master (allowed: BENCH_ALLOW_STALE_BASE=1)"
            else
                echo "GATE FAIL [ancestry] base does NOT contain upstream/master: ${behind:-?} commits behind" >&2
                echo "  A stale base is not the projected-merged future, and a fix whose upstream form" >&2
                echo "  touches a restructured path may be impossible to apply.  Rebase onto" >&2
                echo "  upstream/master, or set BENCH_ALLOW_STALE_BASE=1 if the old base is deliberate." >&2
                fail=1
            fi
        fi
    else
        echo "  note [ancestry] no upstream/master ref here; ancestry unchecked"
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "REFUSING TO BENCHMARK: base is missing a required fix (see GATE FAIL above)." >&2
    echo "Add the named PR's commits to the base and re-run this gate before launching." >&2
    exit 1
fi
echo "bench-base-gate: PASS -- all required fixes present."
exit 0
