# Publishing Hygiene (Rule 0)

The leak-scan gate. Runs before ANYTHING leaves this host to a public remote: every commit,
push, PR body, PR title, and PR/issue comment. Re-banked 2026-08-17 (original lost in churn).
This file is host-local; never publish it.

## What must NEVER appear in anything public (commit / branch / PR body / comment)

- **AWS account IDs** (e.g. the current fred acct number) and ANY AWS resource IDs: instance
  `i-*`, security-group `sg-*`, subnet `subnet-*`, VPC `vpc-*`, volume `vol-*`, AMI `ami-*`,
  snapshot `snap-*`.
- **Keypair names**, `.pem` paths, IAM user names, AWS profile names.
- **Egress IPs / prefixes** (the operator's Starlink / XSTREAM / any home-connection addresses).
- **Instance-type / testbed identifiers** used privately (e.g. the specific metal instance type),
  campaign/operator/roadmap tags, D-numbers, internal goal-phrases, internal codenames.
- **Benchmark-harness specifics that identify the private testbed** — the *tool* (HammerDB) and
  any run parameters/numbers that fingerprint the private setup. Generic technical framing
  ("concurrent connections", "a forked-process server under load") is fine; testbed-identifying
  numbers are not.
- **`.local` contents, build recipes, infra config.**
- **Em-dashes** (—) — a stylistic tell; use `-`.

## What is KEEP (belongs in public work)

- Greg Burd authorship + copyright ("Copyright (C) 2026 Greg Burd" on new files).
- Generic technical content: the mechanism, the code, the reasoning, generic performance
  framing.
- Real hardware/feature names that are legitimately public: `aws_nitro`, ENA, virtio, OpenZFS,
  NVMe, etc.

## The scan (run on the diff + message + any published text)

Grep, case-insensitive, for the leak tokens. Current-era pattern (update the IP/acct literals as
they rotate):

```
grep -iE '<acct-id>|sg-0|vpc-|subnet-|vol-|ami-|snap-|i-0[0-9a-f]{16}|\.pem|<egress-prefixes>|—|ponytail|HammerDB|<private-instance-type>|campaign|roadmap|egress' <target>
```

Known false positives (OK to pass): a git SHA hex matching a loose IP regex; the word "egress"
inside "regression"; "aws_nitro"/ENA as legitimate hardware names. Eyeball, don't auto-fail on
those.

## Procedure

1. Stage EXPLICITLY-NAMED files only (never `git add -A`).
2. Run the scan on: the staged diff, the commit message, the PR title+body, every comment body.
3. Rule-2 second pass (a reviewer confirms clean + correctness + conf_fork=0 byte-identical).
4. Verify `%G?` == `G` (signed).
5. Only then push / open / comment. Re-verify `%G?` == `G` after push.

## History (why this gate exists)
- A prior session committed `.local/` (with AWS account IDs, SG/VPC/subnet IDs, keypair, egress
  IPs) and pushed it to the PUBLIC fork on several branches. Remediated: deleted the leaking
  branches (none a PR head), rebuilt the fix branch clean, force-pushed; verified 0 branches
  contain the leak commit. Codeberg (private) never had it.
- A separate burner account was T&C-shut-down for a 0.0.0.0/0:22 SG rule (a different agent).
  Both incidents are why the never-0.0.0.0/0 and never-push-infra rules are hard gates.
