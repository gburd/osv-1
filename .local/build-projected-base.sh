#!/usr/bin/env bash
# build-projected-base.sh -- construct a benchmark base from the PROJECTED-MERGED
# FUTURE: upstream/master + all our open, non-draft, mergeable PRs, composed in
# order.  Reports every PR as IN / EXCLUDED(reason) / CONFLICT so the base can
# never silently omit a fix we expect to land.
#
# Usage:
#   build-projected-base.sh [--scope full|pg] [--apply <new-branch>]
#     (no --apply)   dry-run: classify every PR, print the plan, compose in a
#                    scratch worktree to detect conflicts, do NOT create a branch.
#     --apply BR     actually build branch BR (cherry-picking / merging the IN set);
#                    stops and reports if a PR conflicts so it can be resolved once.
#   --scope pg (default): workload-scoped for PG-on-ZFS (storage/sched/vfs/fork/mm);
#             full: every eligible non-draft PR.
#
# Requires: gh, git, a worktree-able osv repo, upstream remote = cloudius-systems/osv,
# gh-fork remote = the author's fork.  Run from the repo root.

set -uo pipefail
REPO="cloudius-systems/osv"
UPSTREAM="upstream/master"
SCOPE="pg"
APPLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --scope) SCOPE="$2"; shift 2 ;;
        --apply) APPLY="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# --- exclusions (kept here explicitly so every exclusion has a visible reason) ---
# DO-NOT-MERGE / tracking:
DNM="1458"
# Superseded (predecessor -> keep successor).  Extend as needed.
SUPERSEDED=""
# Workload-scoped deny-list for PG-on-ZFS, BY NUMBER with a reason each.  Default is
# IN: every non-draft, non-DNM PR is part of the projected-merged future unless it is
# listed here as irrelevant to (or a conflict risk for) the local-NVMe PG workload.
# Deny only what is genuinely not exercised; a title-regex over-excludes (it dropped
# setlocale, which PG calls) so this is an explicit, auditable per-PR list.
#   number:reason
PG_DENY="\
1424:Crucible distributed storage, not local-NVMe PG \
1442:IPv6 network stack, no local-NVMe PG effect \
1459:OpenZFS-on-aarch64 enablement, x86 PG run \
1463:virtio-net multiqueue, not the PG storage path \
1467:virtio-net RX wakeup batching, network only \
1470:virtio-net RSS, network only \
1471:Nitro inbound TCP, network only \
1490:aarch64-only, x86 PG run \
1491:aarch64-only, x86 PG run \
1492:early /dev/random, no PG-at-scale effect \
1493:aarch64-only, x86 PG run"

echo "== projected-merged base, scope=$SCOPE, upstream=$UPSTREAM =="
echo "== classifying open PRs (author) =="

# Pull the live list: number, draft flag, mergeable, title, head oid.
gh pr list --repo "$REPO" --author gburd --state open --limit 100 \
    --json number,isDraft,mergeable,title,headRefName,headRefOid \
    > /tmp/.pmb.$$ 2>/dev/null || { echo "gh pr list failed" >&2; exit 1; }

# Parse the deny-list "num:reason num:reason ..." into a form Python can read.
DENY_ENV="$PG_DENY"

IN_PRS=""
python3 - "$SCOPE" "$DNM" "$SUPERSEDED" "$DENY_ENV" < /tmp/.pmb.$$ > /tmp/.pmb.plan.$$ <<'PY'
import json,sys
scope,dnm,superseded,deny_raw = sys.argv[1],set(sys.argv[2].split()),set(sys.argv[3].split()),sys.argv[4]
deny={}
for tok in deny_raw.split():
    if ":" in tok:
        num,reason=tok.split(":",1); deny[num]=reason.replace("_"," ")
prs=json.load(sys.stdin)
inlist=[]
for p in sorted(prs,key=lambda x:x["number"]):
    n=str(p["number"]); t=p["title"]; draft=p["isDraft"]; merg=p["mergeable"]
    reason=None
    if draft: reason="DRAFT (not expected to merge as-is)"
    elif n in dnm: reason="DO-NOT-MERGE / tracking"
    elif n in superseded: reason="superseded by a successor PR"
    elif scope=="pg" and n in deny: reason="deny-list: "+deny[n]
    if reason:
        print(f"EXCLUDE\t{n}\t{reason}\t{t[:52]}")
    else:
        print(f"IN\t{n}\t{merg}\t{t[:52]}")
        inlist.append(n)
sys.stderr.write(" ".join(inlist))
PY
IN_PRS=$(python3 - "$SCOPE" "$DNM" "$SUPERSEDED" "$DENY_ENV" < /tmp/.pmb.$$ 2>&1 >/dev/null <<'PY'
import json,sys
scope,dnm,superseded,deny_raw=sys.argv[1],set(sys.argv[2].split()),set(sys.argv[3].split()),sys.argv[4]
deny=set(t.split(":",1)[0] for t in deny_raw.split() if ":" in t)
prs=json.load(sys.stdin); out=[]
for p in sorted(prs,key=lambda x:x["number"]):
    n=str(p["number"])
    if p["isDraft"] or n in dnm or n in superseded: continue
    if scope=="pg" and n in deny: continue
    out.append(n)
print(" ".join(out))
PY
)
column -t -s$'\t' /tmp/.pmb.plan.$$
echo ""
echo "IN set: $IN_PRS"

# Compose (dry-run or apply) in a scratch worktree at upstream/master.
WT="/tmp/.pmb-wt.$$"
git worktree add -q --detach "$WT" "$UPSTREAM" || { echo "worktree add failed" >&2; exit 1; }
cleanup() { git worktree remove "$WT" --force 2>/dev/null; rm -f /tmp/.pmb.$$ /tmp/.pmb.plan.$$; }
trap cleanup EXIT
cd "$WT"

conflicts=""
for n in $IN_PRS; do
    oid=$(gh pr view "$n" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null)
    [ -z "$oid" ] && { echo "  ?? #$n: no head oid" >&2; continue; }
    git fetch -q gh-fork "$oid" 2>/dev/null || git fetch -q upstream "pull/$n/head" 2>/dev/null
    # Try to merge the PR head; a real conflict is reported, not resolved here.
    if git merge --no-edit --no-ff -q "$oid" 2>/dev/null; then
        echo "  merged #$n ($oid)"
    else
        git merge --abort 2>/dev/null
        conflicts="$conflicts $n"
        echo "  CONFLICT #$n ($oid) -- needs manual resolution"
    fi
done

echo ""
if [ -n "$conflicts" ]; then
    echo "CONFLICTING PRs (resolve once, then re-run):$conflicts"
fi

if [ -n "$APPLY" ] && [ -z "$conflicts" ]; then
    git branch -f "$APPLY" HEAD
    echo "built branch $APPLY at $(git rev-parse --short HEAD)"
elif [ -n "$APPLY" ]; then
    echo "NOT creating $APPLY: resolve the conflicts above first."
    exit 1
else
    echo "dry-run complete (no branch created). Re-run with --apply <branch> to build."
fi
