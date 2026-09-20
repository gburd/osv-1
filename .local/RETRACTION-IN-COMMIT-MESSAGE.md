# Fourth defect class: a retraction that lands in the PR body but not the commit message

2026-09-09, found by agent d9fa6c6e. **This is the one that outlives the review**, and the round-10
harness structurally could not see it: that harness compared the PR *thread* against the head *code*,
and a commit message is neither.

## Why it is worse than a stale PR body
**A PR body is editable forever; a commit message is what gets merged into git log permanently.** A
retraction that lands only in the body does not survive the merge. The maintainer merges the wrong
claim into history.

## Two live instances, both verified by me

**#1476** (head `c6d1c2156`, 1 commit, DRAFT). Body now says the throughput claim "was unsupported by
a single stable number and is corrected here." The head commit message still says, unconditionally:

    line 18: "collapses the per-request halt/wake VM-exit round-trip and lifts throughput
              at high concurrency"
    line 10: "-- not any lock, fault, or TLB cost -- becomes the throughput ceiling"

Grep for host-conditionality in that message returns **0** hits: no `halt_poll`, no "no-op", no
"redundant", neither measured host result. **The reframe I did today landed in the body ONLY.**

**#1447** (head `06210dfcf`, 9 commits, DRAFT). Body explicitly withdraws the write-parity claim
("Both the number and the parity claim are withdrawn"). Commit `f20b91d75` still opens:

    "The local-NVMe A/B showed ext4 sequential reads at ~33% of Linux while writes
     were at parity and random reads ~86%."

The retracted claim is **load-bearing** there - it is the stated motivation for the whole commit. And
it survives in `pr/ext4-perf-v2` as `4ca6429df`, so repointing to v2 would carry the defect along.

## Decisions (they differ, deliberately)

**#1476: rewrite authorised.** DRAFT, single commit, unreviewed, nothing built on it - so a divergent
push costs nothing and leaving it costs a permanently wrong message in upstream history. **Push to a
NEW branch** (`pr/sched-idle-spin-v2`) rather than force-pushing, then repoint #1476 **in the same
pass**. The new message must carry the mechanism plus **both** measured host results
(halt_exits 48975 -> 434 on qemu 8.1.3; 57692 -> 58084 unchanged on a later host with `halt_poll_ok`
already covering ~46k of ~58k halts) and say plainly that the effect is host-conditional and null
where KVM's adaptive halt-polling already catches those wakes.

**#1447: report only, do NOT rewrite.** 9 commits, DRAFT, blocked on a genuine ext4 re-measurement on
a base containing `af27ba4b7`; the branch will be rebuilt anyway. Rewriting 9 messages now is churn
against content that is about to change. Instead **disclose in the body** that the commit messages
still contain the withdrawn claim and will be corrected at re-measurement - worded as a disclosure of
current state, not as another promise I might fail to land.

## The harness is now a THREE-way check
For every PR compare: (1) the thread's corrections, (2) the head code, (3) **every commit message on
the head**. Asked for the message check across **all** open PRs, not only the six with
correction-signature phrasing, since a wrong commit message can exist with no correction comment at
all.

## Permanent checklist entry
**A retraction must land in the body, the commit message, AND the code - and each must be verified
separately.**

## The pattern, now four deep
All four of today's process defects share one shape: **an artifact that is internally self-consistent
and wrong only against something nobody checks.**
1. **#1497's verification table** - coherent prose, wrong against the resolver until executed.
2. **The unlanded correction** - thread coherent, head coherent, only the mismatch wrong.
3. **The `conf_fork=0` break** - correct under the config we always build, broken in the one we never
   build.
4. **This** - correct in the body, wrong in the artifact that outlives the review.
None is detectable by review, `merge-tree`, or a leak scan. The common defence: **execute or compile
the thing rather than read it, and check the artifact against the thing nobody exercises.**

## A GitHub constraint I had wrong: a PR's head branch is NOT editable

Agent d9fa6c6e discovered this while trying to execute my authorisation, and proved it with controls
rather than reporting a failure:

    PATCH /repos/.../pulls/1476  -f head=gburd:pr/sched-idle-spin-v2
      -> returns 200, but .head.ref is UNCHANGED (still pr/idle-spin-tunable)
    Control 1: -f head=gburd:this-branch-does-not-exist-xyz
      -> ALSO returns 200, ALSO ignored  => `head` is silently DISCARDED, not validated
    Control 2: -f base=master
      -> works  => the endpoint is fine; `head` specifically is not writable

**So "retarget the PR to that branch" is never a valid recommendation.** The only options for
correcting a commit message on an existing PR are **force-push** or **recreate**. I have made the
retarget suggestion more than once today, including on #1447, where it turns out **the ask was never
actionable by anyone** - which also explains why it had sat there.

## Resolution for #1476: recreate, not force-push
Verified the recreate is safe: `#1476` is DRAFT with **0 comments, 0 reviews, 0 cross-references**,
and the corrected commit `296b9ec66` has a tree **byte-identical** to the old head `c6d1c2156` (both
`8c1e06ee8bc6c726c9e8bff72758cc4f68c14b08`), so this is a pure commit-message correction with zero
code change. `%G?`=G, merge-tree against upstream/master exits 0.

Chose recreate over force-push deliberately: the no-force rule exists so I do not have to
re-litigate the risk case by case, and recreating achieves the same outcome without touching the
rule. Precedent: **#1439 is itself a recreation of #1421.**

Required it be done in **one pass** - close #1476 and open the replacement together, each referencing
the other - because a closed PR pointing at a replacement that does not exist yet, or a new PR that
silently orphans the old one, is another variant of the #1497 defect.

## #1447 consequence
The "retarget to `pr/ext4-perf-v2`" suggestion in that thread is **impossible**. When the ext4
re-measurement finally happens, that branch will have to be **recreated as a fresh PR**, not
repointed. Better known now than discovered at landing time.

## Behaviour worth naming
The agent **declined to post a comment on #1476 announcing a corrected branch it had not yet landed**,
explicitly because that would reproduce the #1497 defect. That is the second time today an agent
refused to make a promise it could not immediately keep - unprompted, from a lesson banked hours
earlier.
