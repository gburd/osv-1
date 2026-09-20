# Leak #2 REAL-FIX box

- **METAL: `i-0a13d716cee541d70`** m5d.metal, us-east-2, AWS acct 769093516156 (lava profile), Owner=agent-leak2real
- AMI: ami-0dc1629a58a7d6458 (Debian 12), key osv-lava (~/.ssh/osv-lava), SG sg-0a954e440478e063d (osv-bench),
  subnet subnet-0230d1c45d8a098a7
- Purpose: REAL fix for leak #2 (per-fork ~0.77MB unreclaimable). Root-cause histogram FIRST (app-vs-kernel),
  then scope missed kernel sites + per-AS overflow region with NO-OP free reclaimed on reap. 5-part gate.
- Base: gh-fork bench/leakhunt @ ac6a389d2 (leak #1 fd fix + OSV_LEAK_PROBE), apps 3f93f43, ZFS pinned.

## TERMINATE (always, even on failure):
## aws ec2 terminate-instances --profile lava --region us-east-2 --instance-ids i-0a13d716cee541d70

## STATUS: DONE. ALL 5 GATES PASS. Real fix banked. Box TERMINATED (0 orphans, 0 volumes confirmed).

## OUTCOME: The real fix works and is banked (supersedes grow-mitigation).
- STEP 1 histogram: leak is 99.87% app-lifetime (PG heap); kernel-lifetime in fallback = 0.056%.
- STEP 2 fix: per-AS COW-private overflow region (slot 97) + NO-OP free (BSS range check) + wholesale
  reclaim on reap + preemptable-context guard + 1MiB regions (32MiB eager-populate OOMs) + env gate
  OSV_FORK_ARENA_RECLAIM (default on).
- MASKING INSIGHT: the per-AS overflow region exposed latent cross-AS fork-coherence bugs the
  COW-mapped-everywhere arena was hiding. AUDIT found a BOUNDED set (8 sites): socket, inpcb x3,
  serial_timer_task x6, net_channel, ztx_handle, stdio FILE. All scoped to identity heap.
- 5-GATE VALIDATION (400 rounds, 26,181 backends): mem_free FLAT, 0 crash, CORRUPT=0, 0 cross-AS
  faults (gate d at scale), identity fallback -> 16MB bounded (vs 17,289MB leak arm).
- BANKED: gh-fork bank/fork-arena-real-reclaim (2 G-signed commits, probe-stripped, byte-for-byte
  matches validated tree). #1458 section updated with mechanism + 5-gate table + supersedes note.

## TERMINATE (done):
## aws ec2 terminate-instances --profile lava --region us-east-2 --instance-ids i-0a13d716cee541d70
