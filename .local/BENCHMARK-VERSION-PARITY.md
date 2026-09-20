# Version parity is a gate, not a caveat

2026-09-07. User correction, accepted: I allowed a confounded comparison and tried to
paper over it with a footnote.

## The error

The Linux baseline arm was set up with **PostgreSQL 16.15** (Ubuntu's apt package, chosen
because it was fast to install) while both OSv arms run **PostgreSQL 18.6** (built from
source by `apps/postgres18-musl`). I noticed the gap and instructed the agent to "state it
as a caveat, do not hide it."

**That was the wrong fix.** A caveat does not repair a confound. In a comparison whose only
intended independent variable is the platform (OSv-on-metal vs OSv-in-Firecracker vs
Linux), a 2-major-version difference in the application under test makes the result
uninterpretable: PG 16 -> 18 changed WAL handling, added the `io_method`/AIO paths, and
altered vacuum behaviour, all of which sit directly on the paths this campaign measures.
Any delta could be attributed to OSv or to PostgreSQL, and nothing in the data would
distinguish them.

## The rule

**Every component except the independent variable must be identical, and identity must be
PROVEN, not assumed.** For this campaign the independent variable is the platform. So the
application, its version, its build configuration, the filesystem and its properties, the
GUCs, the dataset, and the load generator all have to match across arms.

## Matched PG 18 recipe, extracted from `apps/postgres18-musl/build.sh`

    PG_BRANCH = REL_18_STABLE
    source    = https://github.com/postgres/postgres/archive/refs/heads/REL_18_STABLE.tar.gz
    configure = --prefix=<p> --without-icu --without-zlib --without-readline \
                --without-libxml --without-lz4 --without-zstd
    CFLAGS    = -O2 -g -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0 \
                -DWAIT_USE_SELF_PIPE [-mno-outline-atomics on aarch64 ONLY] \
                -idirafter /usr/include

Keeping the `--without-*` set matters: it gives both builds the same feature surface, not
just the same version number.

## The one residual difference, stated rather than hidden

The OSv build is musl against OSv's libc; the Linux build is glibc on Ubuntu. That is
**intrinsic to the platforms being compared** and cannot be eliminated without changing
what is under test. It is therefore declared as the single known build difference, and both
sides must report `select version()` so the minor versions are on the record (if
REL_18_STABLE now yields 18.7 while the OSv arms measured 18.6, that gets said, not
smoothed over).

## Result identity, extended again

Already: **(osv SHA, apps SHA, zfs banner)**. Now also **(PG branch, PG version string,
configure line)** for every arm. A number that cannot be attributed to all of those is not
attributable.

## Why this was cheap to fix and would have been expensive not to

Caught while the agent had built no schema yet (pool held 42.8 MB, no data), so the cost
was a source build rather than a discarded 200-warehouse dataset and a full sweep. Had it
run to completion, the entire Linux baseline would have been unusable and I would likely
have compared against it anyway, since the number would have looked plausible.

Same failure family as the others this session: **something that still produces a
confident-looking number while silently invalidating it** (ext_fsync == vop_nullop; the
swallowed git apply error; ramfs PGDATA; bsd_zfs masquerading as ZFS; the dangling apps
pin). The countermeasure is identical: prove the substrate and the configuration, do not
accept a label or a footnote in place of evidence.

## A second confound found by the agent: `io_method`

The Linux agent flagged six residual deltas. **Five were false** - it was reading
`.local/HAMMERDB-BENCHMARK.md`, which records HISTORICAL runs (40 warehouses,
autovacuum=off, shared_buffers=2GB, checkpoint_timeout=1h, VU8, 3-min) from an earlier arc.
This campaign's OSv arms were re-run today against the same mandate the Linux arm was
given, verified in their own reports:

    x86 (73a332f26):     autovacuum ON, shared_buffers 16GB, effective_cache_size 32GB,
                         max_connections 400, max_wal_size 16GB, min_wal_size 2GB,
                         checkpoint_timeout 15min, completion_target 0.9,
                         autovacuum_naptime 15s, 200 warehouses / 19 GB
    aarch64 (eb164dcd):  autovacuum ON, shared_buffers 16GB, max_connections 400,
                         max_wal_size 16GB, checkpoint_timeout 900

Lesson for briefs: **name the exact reference document.** "Match the OSv arms" is ambiguous
when the repo contains months of superseded configs, and the stale doc was the more
prominent one. Told the agent to use X86-RESULTS-2026-09-07.md and
AARCH64-RESULTS-2026-09-07.md as the comparison target.

**The sixth delta is real and I had missed it: `io_method`.** The OSv arms run
`io_method=sync` not as tuning but because **OSv's AIO path is incomplete**
(`apps/postgres18-musl/build.sh:164`). PG 18 on Linux defaults to `io_method=worker`. Left
unmatched, I would be comparing OSv's synchronous I/O against Linux's worker-based AIO and
attributing the difference to "the platform" when part of it is a PG feature OSv cannot yet
use.

Resolution: **set `io_method=sync` on Linux** for the primary sweep, and state plainly that
this isolates the platform variable while **understating what Linux+PG18 can do in
production**. Requested an OPTIONAL secondary series at `io_method=worker`, clearly
separated, because that difference quantifies **what completing OSv's AIO path is worth** -
a directly useful platform-roadmap number rather than a nuisance.

## The residual confound I cannot fix cheaply: guest geometry

Linux box is m5d.4xlarge (16 vCPU VM); the OSv arms were 32-vCPU guests on m5d.metal.
Instructed: keep the box, report per-vCPU normalised figures, and state the geometry
difference prominently alongside musl-vs-glibc as the primary residual confounds. Offered a
32-vCPU box if the agent judges same-geometry essential (quota is 512 now), with the
explicit instruction to tell me rather than decide silently.

## Context that lowers the stakes on exact matching
Neither OSv arm produced a NOPM table - both crashed in the ELF/dlopen path before the
timed window opened. So the Linux run is currently the ONLY throughput data in the
campaign. Its job is to establish the reference that OSv gets measured against once the
kernel bug is fixed, not to match numbers that do not yet exist.
