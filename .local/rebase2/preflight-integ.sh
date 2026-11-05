#!/usr/bin/env bash
# preflight-integ.sh -- does CANDIDATE carry the reviewed projected-merged set?  A thin wrapper that only
# chains the repaired gates, in order, and fails closed.  It holds no PR list, exclusion or claim of its
# own: the manifest decides every disposition (including #1424's).
#
# Usage (run inside the repository):
#   preflight-integ.sh --manifest M --candidate REV [--dispositions D] [--inventory INV]
#                      [--prs-json PAGES.json --prs-total TOTAL.json]
#   1. ../check-inventory.sh --inventory INV [--live-json PAGES --live-total TOTAL]    exit 0 required
#   2. ../build-projected-base.sh --plan-only --manifest M [--prs-json ... --prs-total ...]
#                                                exit 0 required; 3 (BLOCKED rows) fails the preflight
#   3. ./pr-presence.sh N HEAD BASE CANDIDATE [D] for every INCLUDE row of the plan.  HEAD and BASE come
#      from the composer's frozen snapshot (NEWDIR/prs.json), never from a live query.  BASE is
#      merge-base(snapshot base.sha, HEAD), the base of GitHub's PR diff.  It runs in the composer's
#      scratch store (NEWDIR/store), which holds exactly the heads the composer verified and borrows the
#      repo's objects through alternates, so the repository is never written.
#   Without --prs-json/--prs-total the wrapper freezes ONE snapshot (the same two GETs the gates use) and
#   hands it to gates 1 and 2, so all three judge the same PR set.  INV defaults to the inventory next to
#   check-inventory.sh.
#   4. CANDIDATE^{tree} must equal the plan's FINAL tree (FAIL[preflight-tree]): this is what checks the
#      ALTERNATIVE commits and that CANDIDATE carries nothing beyond the reviewed plan.  A whole PR left out
#      needs a manifest row; --dispositions only waives per-path DIFFERS on a candidate whose tree == FINAL.
# Exit 0 all gates pass.  1 a gate failed; every inner FAIL[tag] line is printed.  2 usage, an
# unreadable manifest, or a missing or non-executable gate; no gate was run.
# Not checked here: base ancestry, the build log and runtime levers.  Those belong to bench-preflight.sh
# (TOOL-7), so run it directly.  --build-log/--runtime-proof are refused, never dropped.
# Negative oracle (must stay green): .local/tool-repair/run-negative-preflight.sh
#
# History (TOOL-6b repair, 2026-10-08): the prior version exported a hard-coded BENCH_SKIP_PRS of 9 PRs
# with stale reasons: the Crucible #1424 exclusion, RNG and "superseded variant" claims, and the fork series.
# It ran none of the inventory, composer or presence gates and exec'd bench-preflight.sh, whose heuristic
# presence output was then read as certification.  Backup: preflight-integ.sh.pre-repair-20261007.
set -uo pipefail
export LC_ALL=C GIT_OPTIONAL_LOCKS=0
HERE=$(cd "$(dirname "$0")" && pwd)
INVG=$HERE/../check-inventory.sh COMP=$HERE/../build-projected-base.sh PRES=$HERE/pr-presence.sh
INV=$HERE/../UPSTREAM-INVENTORY.md MANIFEST='' CAND='' DISP='' PRS_JSON='' PRS_TOTAL=''

usage() { echo "FAIL[usage]: $*"; exit 2; }
while [ $# -gt 0 ]; do
    case $1 in
        --manifest|--candidate|--dispositions|--inventory|--prs-json|--prs-total)
            [ $# -ge 2 ] || usage "$1 needs a value" ;;&
        --manifest)     MANIFEST=$2; shift 2 ;;
        --candidate)    CAND=$2; shift 2 ;;
        --dispositions) DISP=$(realpath -m -- "$2"); shift 2 ;;
        --inventory)    INV=$2; shift 2 ;;
        --prs-json)     PRS_JSON=$2; shift 2 ;;
        --prs-total)    PRS_TOTAL=$2; shift 2 ;;
        --build-log|--runtime-proof) usage "$1 belongs to bench-preflight.sh (TOOL-7): run it directly" ;;
        *) usage "unknown argument '$1'" ;;
    esac
done
[ -n "$MANIFEST" ] && [ -n "$CAND" ] || usage "--manifest M and --candidate REV are required"
{ [ -f "$MANIFEST" ] && [ -r "$MANIFEST" ]; } || { echo "FAIL[manifest]: cannot read $MANIFEST - nothing run"; exit 2; }
if [ -n "$PRS_JSON$PRS_TOTAL" ] && { [ -z "$PRS_JSON" ] || [ -z "$PRS_TOTAL" ]; }; then
    usage "--prs-json and --prs-total go together"
fi
for g in "$INVG" "$COMP" "$PRES"; do
    { [ -f "$g" ] && [ -x "$g" ]; } || { echo "FAIL[gate]: $g is missing or not executable - nothing run"; exit 2; }
done
C=$(git rev-parse -q --verify "$CAND^{commit}") || usage "candidate '$CAND' is not a commit in this repository"
W=$(mktemp -d "${TMPDIR:-/tmp}/preflight-integ.XXXXXX") || usage "mktemp -d failed"
echo "preflight-integ: candidate $CAND = $C; receipts $W (kept)"
die() { echo "FAIL[$1]: $2"; echo "PREFLIGHT FAILED"; exit 1; }
if [ -z "$PRS_JSON" ]; then   # freeze ONE snapshot (GET only) so all three gates judge the same PR set
    PRS_JSON=$W/prs.json PRS_TOTAL=$W/total.json
    gh api --paginate --slurp 'repos/cloudius-systems/osv/pulls?state=open&per_page=50&sort=created&direction=asc' \
        >"$PRS_JSON" && gh api 'search/issues?q=repo:cloudius-systems/osv+is:pr+is:open&per_page=1' >"$PRS_TOTAL" \
        || die gh "could not freeze the PR snapshot"
fi
inv=(--inventory "$INV" --live-json "$PRS_JSON" --live-total "$PRS_TOTAL")
snap=(--prs-json "$PRS_JSON" --prs-total "$PRS_TOTAL")

echo "== 1/3 check-inventory.sh"
"$INVG" "${inv[@]}"; rc=$?
[ $rc = 0 ] || die preflight-inventory "check-inventory.sh exit $rc"

echo "== 2/3 build-projected-base.sh --plan-only"
P=$W/plan
"$COMP" --plan-only --manifest "$MANIFEST" --out "$P" "${snap[@]}"; rc=$?
[ $rc != 3 ] || die preflight-blocked "composer exit 3: BLOCKED rows remain, the set is not composable"
[ $rc = 0 ] || die preflight-composer "composer exit $rc"

echo "== 3/3 pr-presence.sh per INCLUDE row (heads/bases from $P/prs.json)"
grep -qxF "manifest $MANIFEST sha256 $(sha256sum <"$MANIFEST" | cut -c1-64)" "$P/plan.txt" 2>/dev/null \
    || die preflight-plan "$P/plan.txt does not record this manifest's sha256 (changed during the run, or no plan)"
sv=$(jq -r '[.[][]] | .[] | "\(.number) \(.head.sha) \(.base.sha // "-")"' "$P/prs.json") \
    || die preflight-snapshot "cannot read the composer's frozen snapshot $P/prs.json"
declare -A SH SB
nsnap=0
while read -r n h b; do [ -n "$n" ] && SH[$n]=$h SB[$n]=$b nsnap=$((nsnap + 1)); done <<<"$sv"
inc=() rows=0
while IFS= read -r l; do
    [[ $l =~ ^#([0-9]+)\ ([0-9a-f]{40})\ draft=[^\ ]+\ author=[^\ ]+\ (.+)$ ]] || continue
    rows=$((rows + 1))
    [ "${BASH_REMATCH[3]}" != INCLUDE ] || inc+=("${BASH_REMATCH[1]} ${BASH_REMATCH[2]}")
done < <(sed -n '/^## dispositions/,/^## steps/p' "$P/plan.txt")
[ "$rows" = "$nsnap" ] && [ "${#inc[@]}" -gt 0 ] \
    || die preflight-plan "plan.txt has $rows disposition rows (${#inc[@]} INCLUDE) for $nsnap snapshot PRs"
sg() { env -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
       GIT_DIR="$P/store" "$@"; }
sg git rev-parse --git-dir >/dev/null 2>&1 || die preflight-plan "no composer store at $P/store"
bad=0
for r in "${inc[@]}"; do
    read -r n ph <<<"$r"; h=${SH[$n]:-} b=${SB[$n]:-}
    if [ "$h" != "$ph" ] || ! [[ $b =~ ^[0-9a-f]{40}$ ]]; then
        echo "FAIL[preflight-snapshot]: #$n snapshot head '$h' base '$b' (plan head $ph)"; bad=1; continue
    fi
    if ! mb=$(sg git merge-base "$b" "$h" 2>/dev/null); then
        echo "FAIL[object]: #$n no merge-base of snapshot base $b and head $h (fetch upstream?)"; bad=1; continue
    fi
    sg "$PRES" "$n" "$h" "$mb" "$C" ${DISP:+"$DISP"} >"$W/presence-$n.log" 2>&1; rc=$?
    grep -E '^(FAIL\[|WARN|NOTE|RESULT)' "$W/presence-$n.log"
    [ $rc = 0 ] || { echo "FAIL[preflight-presence]: #$n pr-presence.sh exit $rc (receipt presence-$n.log)"; bad=1; }
done
# REVIEW F1/F2: the candidate is exactly the reviewed plan (ALTERNATIVE commits in, nothing unreviewed on top)
mapfile -t fl < <(grep -E '^FINAL ' "$P/plan.txt")
if [ ${#fl[@]} -ne 1 ] || ! [[ ${fl[0]} =~ ^FINAL\ steps=[0-9]+\ tree=([0-9a-f]{40})\  ]]; then
    echo "FAIL[preflight-plan]: $P/plan.txt needs exactly one 'FINAL steps=N tree=<40-hex>' line, found ${#fl[@]}"; bad=1
elif ! CT=$(git rev-parse -q --verify "$C^{tree}"); then
    echo "FAIL[preflight-tree]: cannot read the tree of $C"; bad=1
elif [ "$CT" != "${BASH_REMATCH[1]}" ]; then
    FT=${BASH_REMATCH[1]}
    echo "FAIL[preflight-tree]: candidate tree $CT != plan FINAL tree $FT; paths (plan -> candidate):"
    sg git diff-tree -r --name-status "$FT" "$CT" | head -n 20 | sed 's/^/    /'
    bad=1
else echo "candidate tree $CT == plan FINAL tree"; fi
[ $bad = 0 ] || { echo "PREFLIGHT FAILED"; exit 1; }
echo "PREFLIGHT PASS: inventory in sync, plan clean, all ${#inc[@]} INCLUDE rows present in $C, tree == plan FINAL"
