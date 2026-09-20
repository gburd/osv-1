# OSv ARC sizing: the 2047MB figure EXPLAINED and the "crippled cache" hypothesis REFUTED

## The observation that started it
`OSV_ZFS_ARC_MAX` does **not exist** on `bank/fork-footprint-reduction-signed` (verified by
`git grep` over the whole branch; it lives only on `gh-fork/bench/zil-hires-ab`,
b7dff520d/98b5e58c4). So `--env=OSV_ZFS_ARC_MAX=...` is a **silent no-op** on this base: no
consumer reads it. The a2a's "matched 32GiB ARC both sides" was therefore never enforced on
the OSv side. I added a default-on ARC probe (printf, not debugf) and measured instead.

First reading, at idle:
```
ARCPROBE arc_size_MB=19 arc_c_MB=2047 arc_c_max_MB=32767 zfs_arc_max_MB=0 dirty_max_MB=3276 free_MB=47759 physmem_MB=65535
```
This matches the cwwake MEMPROBE's `arc_c=2047MB`, so it is reproducible, not a fluke.

## The hypothesis it suggested (and that I was asked to elevate)
"OSv's ARC self-limits to 2047MB with 47GB free and a 32767MB ceiling, so a DB host cannot
use its RAM for page cache; 19GB of data against a 2GB cache means OSv does physical IO
where Linux serves from memory — very likely the real cause of the a2a's VU32 gap."

## THE HYPOTHESIS IS REFUTED. arc_c=2047MB is the IDLE FLOOR, not a cap.

### Mechanism, read from the source
- `arc.c:8042` `arc_c_min = MAX(allmem / 32, 2 << SPA_MAXBLOCKSHIFT)` → 64GiB/32 = **2GiB
  exactly**, which is precisely the 2047MB observed. It is the FLOOR.
- `arc.c:8103` `arc_c = arc_c_min` at init — the ARC *starts* at the floor by design.
- `arc.c:5108-5124` `arc_adapt()` **grows** `arc_c` toward `arc_c_max` whenever demand
  approaches the current target (`arc_size + 2*SPA_MAXBLOCKSIZE >= arc_c`).
- `arc_c_max = 32767MB` from `arc_default_max()` = `MIN(5/8*RAM, RAM/2)` for a >2GiB guest.
  That is a deliberate OSv policy (app and ARC share one address space), not a defect.
At idle `arc_size` was 19MB, far below the 2GB floor, so there was **no demand to grow**.
An idle ARC sitting at its floor is correct behaviour, not a limitation.

### Measurement that settles it — I drove real demand (sequential scans of the 19GB dataset)
```
ARCPROBE arc_size_MB=19    arc_c_MB=2047  arc_c_max_MB=32767  free_MB=47742   <- idle floor
ARCPROBE arc_size_MB=875   arc_c_MB=2047  arc_c_max_MB=32767  free_MB=46815
ARCPROBE arc_size_MB=2786  arc_c_MB=2853  arc_c_max_MB=32767  free_MB=44887   <- grows
ARCPROBE arc_size_MB=4876  arc_c_MB=4935  arc_c_max_MB=32767  free_MB=42780
ARCPROBE arc_size_MB=6572  arc_c_MB=6647  arc_c_max_MB=32767  free_MB=41067
ARCPROBE arc_size_MB=7460  arc_c_MB=7563  arc_c_max_MB=32767  free_MB=40197
ARCPROBE arc_size_MB=8290  arc_c_MB=8369  arc_c_max_MB=32767  free_MB=39362   <- still climbing
```
`arc_c` grew 2047 → 8369 MB and `arc_size` tracked it (19 → 8290 MB), consuming guest free
memory as it went (47.7GB → 39.4GB free). The ceiling was never the 2GB floor.

**Conclusion: OSv's ARC IS demand-driven and DOES use the guest's RAM. There is no
"OSv cannot use its RAM for page cache" finding.** Reporting one would have been a false
claim built on a single idle sample.

## Consequences (this is why it mattered)
1. **The a2a's VU32 gap is NOT a cache-size artifact.** Under HammerDB's load OSv's ARC would
   have grown exactly as measured above, so OSv was not running a 16x smaller cache during the
   a2a cells. The #4 mystery is **not** retired by an ARC explanation; the durable-vs-nondurable
   discriminator remains the way to name it.
2. **ARC parity = equal CEILING, and I therefore REVERSED the 2GiB match.** Capping Linux at
   2GiB would have pinned Linux at a floor while OSv grew to ~32G under load — that is not
   equality, it handicaps Linux and inflates OSv. Both arms run a 32GiB ceiling
   (OSv measured `arc_c_max=32767MB`; Linux `zfs_arc_max=34359738368`), and every cell reports
   both arms' measured `arc_c`/`arc_size` so cache state is auditable rather than assumed.
3. The earlier campaign note that "OSv was DISADVANTAGED on cache, so the a2a ratios are
   conservative for OSv" rests on the same idle-sample misreading and should not be relied on.

## What IS a fair (minor) observation, stated without overclaiming
OSv's ARC must *grow into* its ceiling from `allmem/32`, so a short benchmark cell that begins
right after boot spends part of its window with a cold, still-expanding cache. That is a
warm-up characteristic shared with Linux's own cold-ARC behaviour; the hardened quiesce plus
fresh-boot-per-cell discipline applies equally to both arms here. It is not a defect and it
is not the VU32 gap.

## Method note
This is the second time in this run that a proof line beat an assumption: the absent ARC knob
was caught by printing a resolved value, and the "crippled cache" reading was caught by
driving demand instead of trusting one idle sample. Both are the env-audit rule working.
