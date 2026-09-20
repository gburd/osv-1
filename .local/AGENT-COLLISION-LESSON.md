# I put two agents on one box, twice in one day

2026-09-08. A process failure of mine, caught by the agents rather than by me, both times.

## What I did

Two long-running agents appeared stalled. Diagnosis method (sound): elapsed-vs-tool-uses.

    974ed15b  Linux/PG baseline   19.5 h,  18 tool uses,  transcript ends on an unanswered bash call
    924205f9  q35 boot fix        16.1 h,  33 tool uses,  same shape

Both were genuinely blocked inside foreground commands. **But instead of treating their boxes
as owned, I launched replacements and pointed them at the SAME live boxes** to preserve the
setup work, without telling either the original or the replacement that the other existed.

Result, both times: the replacement's work appeared underneath a still-live original.
- On the q35 box, agent 924205f9 noticed `drivers/ahci.cc` modified with a foreign mtime,
  plus `matrix.sh`/`full.sh`/`rebuild.sh` it had not authored, and a `q35work` branch with no
  commits. It **refused to terminate the box** because doing so would destroy an uncommitted
  fix, and asked.
- On the Linux boxes, agent 974ed15b found its PG16 initdb replaced by PG 18.6 from
  `/opt/pg18`, its `postgresql.conf` block swapped for an include of a `conf.bench.conf` it
  had not written, the 200-warehouse schema already built (its `buildschema` failed with
  "Database tpcc exists but is not empty"), and a foreign `sweep.sh` mid-flight on the
  driver. It **paused instead of proceeding.**

Both times the agent made the right call and I had made the wrong one.

## Why 974ed15b's reasoning was the sharpest thing in the episode

It did not merely report "someone else is here". It articulated the consequence: two sessions
sharing one PGDATA and one `/tmp/hdbxtprofile.log` means the other sweep can boot/kill PG and
rotate the profile log mid-measurement, so **any number either session produced would be
contaminated** - and this is the Linux baseline the entire OSv comparison is measured
against. That is this project's signature failure mode (a run that still produces a
confident-looking number while measuring the wrong thing), identified from indirect evidence:
file mtimes, an unfamiliar conf include, a foreign harness running.

Outcome: no contaminated number was published. The replacement's sweep ran after the original
had stopped issuing commands, its results are internally consistent (driver 98% idle, spreads
explained structurally by checkpoint phase), and both boxes are now verified **terminated**.

## Standing rules adopted

1. **Never hand a live agent's box to a replacement.** If an agent looks stalled, either
   (a) let the box be and give the replacement a fresh one, or (b) tell BOTH agents
   explicitly, in writing, who owns what.
2. **A stalled agent is not a dead agent.** Both "stalled" agents later woke up and did
   useful work. 924205f9 went on to root-cause the AHCI/ATAPI hang and then own PR #1499.
3. **Tag boxes with the owning agent id**, so a second agent can tell whose box it is without
   inferring from mtimes.
4. **"Refuse to reap or overwrite a box you did not launch" now has a companion: refuse to
   proceed on a box that shows foreign activity, and ask.** Both agents did this unprompted;
   it should be explicit in briefs.

## Brief corrections banked (durable, independent of the run)

**HammerDB download assets: MY BRIEFS paraphrased the filename; the doc was right.**
`.local/HAMMERDB-BENCHMARK.md` correctly records `HammerDB-6.0-Prod-Lin-RHEL9.tar.gz`. But my
briefs said "HammerDB 6.0 (RHEL9 build)" loosely, so agents tried
`HammerDB-6.0-Linux.tar.gz` and `HammerDB-6.0-RHEL9.tar.gz`, which both **404**. Real assets
use the `-Prod-Lin-<distro>` pattern:
- **`HammerDB-6.0-Prod-Lin-UBU24.tar.gz`** (Ubuntu 24.04, used by the Linux baseline arm)
- `HammerDB-6.0-Prod-Lin-RHEL9.tar.gz` (RHEL9/AL2023)
Lesson: **give agents the FULL filename, never a paraphrase of it.** A paraphrase that looks
plausible sends them to a 404.

**`pg_hba.conf` gap:** the replacement found there was **no rule for 172.31/16**, so the
external driver could never have authenticated. That is plausibly the direct cause of the
original agent's apparent 19-hour hang - it may have been waiting on a connection that could
never succeed. Any future brief must include the `pg_hba.conf` line explicitly and require
proving external reachability with `psql` BEFORE any load run (which the campaign brief did
require, and which is why the OSv arms caught their own networking problems early).
