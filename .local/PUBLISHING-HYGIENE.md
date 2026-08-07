# Publishing hygiene — what must NEVER appear in published git (commits, PR text, code comments, docs)

This project's public artifacts (commit messages, PR titles/bodies/comments, code
comments, committed docs) are read by upstream maintainers and the world. Keep
them about the CODE and its CORRECTNESS. The following categories must be scrubbed
BEFORE anything is pushed to a public remote (gh-fork) or a PR.

## NEVER publish (scrub these)

1. **Cloud vendor / infrastructure specifics used for OUR dev/test/bench.**
   - No "AWS", "Amazon", "EC2", "GCP", instance types (m5d.metal, m5.metal, c6g,
     c7g, Graviton, Nitro-as-our-testbed), "fedora:39 build container",
     "instance store", "377 GiB", "local NVMe instance store", region/AZ, etc.
   - Say it hardware-neutrally: "a 2-socket x86-64 bare-metal host with local
     NVMe, KVM guests", "an aarch64 metal host", "a device-queue-depth sweep".
   - EXCEPTION (allowed, because they are UPSTREAM OSv's own identifiers, not our
     testbed): the `drivers_profile_aws_nitro` kconfig, `conf/profiles/*/aws.mk`,
     the `AWS ENA` driver, "Nitro device drivers" — these are OSv platform names
     that predate us. Do not rename them.
   - BORDERLINE: naming a cloud's DHCPv6/RA behavior as a technical example
     (e.g. "AWS VPC sets the Managed flag") — prefer a neutral phrasing
     ("a Managed-flag DHCPv6 network", "some cloud DHCPv6 servers").

2. **Anything about the operator / process / tooling.**
   - No LLM/agent/assistant/model names (Claude, GPT, Anthropic, OpenAI, Kiro),
     no "agent", "subagent", "dispatched an agent", "steered", "session",
     "prompt", "tool use", "background agent".
   - No `ponytail:` (or any internal shorthand) comment tags in code. If a comment
     marks a deliberate simplification, write it as a plain `// TODO:` or
     `// note:` with the technical content only.
   - No references to the multi-agent workflow, banking-to-disk, box orchestration,
     "I dispatched / re-dispatched", retry/cutoff mechanics, etc.
   - No internal routing tags in PUBLIC commit messages (e.g. `[#1423/OpenZFS]`,
     `[fork-stack]` are fine as our internal classification but reword to clean
     public messages when the commit lands on a public PR — a plain scope prefix
     like `zfs:` / `mm:` / `libc:` is what upstream expects).

3. **The end-goal framing that reveals strategy/process.**
   - Avoid "a target for Postgres-over-ZFS", "the benchmark sweep", "our A/B" as
     justification prose. State the technical motivation neutrally ("helps
     multi-socket NUMA hosts") without narrating the campaign.

## KEEP (intended, not a leak)
- Authorship: `Greg Burd <greg@burd.me>`, `Signed-off-by:`, `Copyright (C) 2026
  Greg Burd` on new files. This is the intended public identity.
- Real technical content: benchmark NUMBERS and methodology are fine; just
  describe the HOST generically. Upstream driver/platform names (see 1 exception).

## Pre-push checklist (run before EVERY push to gh-fork / before opening/updating a PR)
```
# leak scan of the commits + diff being pushed (adjust <base>):
git log <base>..HEAD --format='%H%n%s%n%b' | \
  grep -inE 'aws|amazon|\bec2\b|\bgcp\b|nitro|m5d|m5\.metal|c6g|c7g|graviton|fedora:39|\bLLM\b|claude|gpt|anthropic|openai|subagent|ponytail|dispatched an|steered|the agent|Postgres-over-ZFS' \
  | grep -viE 'ena |aws_nitro|aws\.mk|profiles.*aws|user agent'
git diff <base>..HEAD | grep -E '^\+' | \
  grep -inE 'aws|amazon|\bec2\b|nitro|m5d|graviton|fedora:39|ponytail|claude|\bLLM\b|subagent|dispatched an' \
  | grep -viE 'ena|aws_nitro|aws\.mk'
# both should be EMPTY (except upstream aws_nitro/ENA and Greg Burd authorship).
```
Also check the PR body/title after opening: `gh pr view <n> --json title,body`.

## If a leak already MERGED to upstream
Submit a small, self-contained "reword a stray internal comment" / "keep prose
vendor-neutral" follow-up PR (e.g. #1462 for the balloon `ponytail:` comment).
Reword only; no functional change.
