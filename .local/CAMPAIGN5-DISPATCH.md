# Campaign 5: port the missing fork half to x86, then finally get the NOPM sweep

2026-09-09, agent ec362954, `Owner=agent-x86complete`.

## Why this is a small, well-defined run rather than open research

**The x86 lineage has only HALF the fork fix**, which I verified:

    branch                              OSV_FORK_RANGE_BS   OSV_FORK_LARGE_SHARE
    wip/fork-clone-scan (x86 base)             2                    0
    wip/forkroot-arm-base (aarch64)            2                    2

Measured consequence:

    aarch64, both halves : 117.3 -> 3.98 ms  vs Linux 4.0-4.3  => AT PARITY
    x86, RANGE_BS only   : 196   -> 78 ms    vs Linux 4.0-4.3  => still ~19x behind

The missing half is `5a8e946f0` - **76 lines, one file, zero arch guards** - which on aarch64 took fork
from 42.6 ms to 3.98 ms by not splitting each 2 MB `shared_buffers` large page into 512 4K PTEs
(n_ptes 4,445,585 -> 132,497).

**I pre-verified the port applies: 4/4 commits cherry-pick cleanly onto `wip/fork-clone-scan`, zero
conflicts.** So this is mechanical, not research:

    8dd6069c5  rofs: shared file cache on the kernel heap (fork-arena coherence)
    9aa67d72f  pagecache: shared page caches on the kernel heap (same rule, 4th instance)
    16149a08b  mm: print resolved fork A/B env flags (proof of binding)
    5a8e946f0  mm: share writable MAP_SHARED 2 MB large pages verbatim across fork

Note `9aa67d72f` is the **fourth instance** of the fork-arena coherence rule documented at
`core/epoll.cc:63-81`, and it lands on `core/pagecache.cc` - the candidate I escalated earlier because
`read_cache` is reachable on our exact config. It exists and is being ported, which closes that loop.

## The falsifiable expectation
`OSV_FORK_LARGE_SHARE=1` should take x86's 78 ms median toward ~4 ms. **If it does not, the aarch64
result is ISA-specific** and that is important news rather than a failure.

## Deliverable 2: the sweep that has now failed three times running
Three consecutive runs produced **zero NOPM**, every time for substrate reasons rather than guest
behaviour. Every trap is enumerated in the brief, including the newest one: **`git submodule update`
silently reverts `apps` to the upstream pin and re-arms the shadowed-build trap**, so both pre-boot
greps must be re-run after any submodule operation.

Explicit instruction to **use HammerDB, not a psql-per-client harness** - the last run could not
distinguish guest serialization from its own harness at VU32 and correctly declined to conclude.
HammerDB holds persistent connections, matching what the Linux baseline used.

## The actual open question
Linux **scales to VU64** (213,505 -> 614,277); the old OSv x86 base **peaked at VU8** (43,407 -> 26,047),
so the gap widens 4.9x -> 21.6x. **Do the fork and VFS fixes change the SHAPE, or only the level?**
Ratios must carry their VU level; a bare "Nx" is meaningless when it quadruples across the sweep.

## Capacity constraint made explicit
**Only ~40 vCPU free (472 of 512 in use; other projects hold two 192-vCPU metal boxes).** An
`m5d.metal` is 96. Told to check headroom first and **wait or report rather than force a launch** - a
failed launch, or contention with another project's live benchmark, is worse than a delayed run. Build
on a cheap box, metal only for the measurement, same osv SHA on both.

## CAPACITY BLOCKER: nothing metal fits, and there is no TCG fallback

Agent ec362954 took my loose "only ~40 vCPU free" caveat, measured it, and turned it into a decision.
I verified every part:

    in use: c8g.metal-48xl 192 + c7i.metal-48xl 192 + c6i.4xlarge 16 + 3x r6id.4xlarge 48
            + c7g.2xlarge 8 + c7i.2xlarge 8 + m5.2xlarge 8  =  472 / 512
    after its 16-vCPU builder: 488/512, 24 free

**No metal instance type fits.** I enumerated them: smallest x86 metal with >=32 vCPU is
`m5zn.metal`/`z1d.metal` at **48**; `c5.metal`/`m5d.metal` are **96**; aarch64
`c7gd`/`m6gd`/`c6gd.metal` are all **64**. None fit in 24.

**And the decisive point, which is the agent's:** no non-metal x86 EC2 instance exposes nested KVM, so
a TCG connect-latency number would be meaningless. **There is no cheap fallback for even Deliverable
1's measurement.** That kills the obvious workaround before I could suggest it.

Quota request `81a28127e...` filed for 512 -> 640, status **CASE_OPENED**. The prior 192 -> 512 request
took ~2 days to close, so approval inside this run's window is unlikely.

## Option (b) declined, with the reasoning on record
Both 192-vCPU boxes belong to **`libumem`** (`libumem-arm-hi` on `c8g.metal-48xl`, `libumem-intel-hi`
on `c7i.metal-48xl`), both launched 18:55 UTC, ~2.5h before - almost certainly mid-benchmark.

**Refused to free them.** The standing rule is "terminate only what you launched", and killing another
project's live measurement to save ourselves a few hours is exactly the trade I have declined all
session. **A delayed measurement is cheap; someone else's destroyed run is not.**

## Revised plan
1. **Finish and push the build** - critical path for both deliverables, needs no virtualization, pure
   progress regardless of capacity. Re-run both pre-boot greps **after** any submodule operation, since
   that is exactly where the last run lost its image.
2. Poll the quota occasionally, not busily.
3. **At ~3 hours with no approval, stop and report build-only** rather than idling to the 6-hour cap. A
   pushed, verified branch plus "measurement blocked on quota, request pending" is a good outcome: the
   next run starts from a validated image instead of from scratch.

## The de-risking task added while it waits
**Verify under TCG that the ported tree boots and runs PostgreSQL end to end** - pool import,
`seed_copy` after the `zfs mount`, PG serving a query from the driver. TCG timings are useless but
**TCG correctness is not**, and three consecutive campaigns have lost their metal hours to substrate
faults a TCG boot would have caught. Also confirm the `FORKFLAG` line prints and `OSV_FORK_LARGE_SHARE`
reads as bound, since `16149a08b` exists precisely to make that observable.

## Quota approved in 40 MINUTES, not two days - my pessimism was wrong in a useful direction
Request `81a28127e...` closed APPROVED, L-1216C47A now **640**. I had told the agent to plan around the
previous request's ~2-day turnaround. **Lesson for sequencing: these get processed fast enough to be
worth filing early and often**, rather than treating capacity as a hard wall to design around.

But headroom moved while it built (other projects added `c7i.4xlarge`, `i4i.16xlarge`, `c6id.4xlarge`,
`c6id.8xlarge`): **568/640, 72 free. `m5d.metal` (96) still does not fit.** It launched
**`m5zn.metal` (48 vCPU / 192 GiB)** instead, which does.

## THE CORRECTION THAT IS MINE, AND IRONIC
The agent found that **the apps pin I specified re-arms the very trap I warned about in the same brief.**
Verified:

    apps@b38b99cd  '.PHONY: module build' -> 0    <- what BOTH bases pin
    apps@5cb1903   '.PHONY: module build' -> 1    <- the fix I landed on osv-apps#73 TODAY
    merge-base --is-ancestor b38b99cd 5cb1903 -> YES (clean ff, exactly one commit)

So following my brief literally produces a **PostgreSQL-free 10 MB image reporting success**.

**Fixed at source so future runs cannot inherit it:** pushed
`gh-fork/wip/pg-v26-faultfix-repinned2` (`5d1ef07c2`, G-signed) re-pinning `apps` to
`5cb19033555d6d4370da905965016f0adb81e515`, verified published and fetchable before pushing. New
branch rather than force-push, per the standing rule.

## Geometry deviation accepted, with two caveats that must be visible not footnoted
`m5zn.metal` is 48 physical cores, so the guest (still **32 vCPU / 64 GiB** as specified) is pinned to
32 dedicated cores with HammerDB on the separate `c5.4xlarge` over the network. The **guest** variable
is preserved; the **host** differs from `m5d.metal` two ways a reader must see:
1. **48 cores versus 96** - qemu threads and the host kernel share the same package as the pinned
   guest, rather than having an idle socket beside them.
2. **m5zn is the high-frequency Cascade Lake part (~4.5 GHz) versus m5d's ~3.1 GHz.** That cuts **in
   OSv's favour** on per-core work, so any improvement over the old `m5d.metal` run is partly clock
   rather than the fix.

Point 2 is the one I most want reported, because it is exactly the kind of thing that silently flatters
a result. Asked for `/proc/cpuinfo` model+MHz from both hosts so the caveat is concrete.

## Deliverable 1 DONE, and it stands alone
    branch: gh-fork/wip/pg-x86-forkroot-largeshare
    HEAD:   42aeb163b
    7/7 cherry-picks clean, merge of wip/fork-clone-scan clean
    flags now BOTH on x86: OSV_FORK_RANGE_BS=2, OSV_FORK_LARGE_SHARE=2, FORKFLAG=1
    all 11 commits %G? == G, no em-dashes, leak-clean
My branch matrix was exactly right: x86 was missing `LARGE_SHARE` and now has it.

## Priority restated for a finite window
1. **Connect A/B first** (`OSV_FORK_LARGE_SHARE` on vs off, same binary, interleaved). Short, and it
   answers the falsifiable question. **Prediction: 78 ms -> ~4 ms. Anything else is news** and would
   mean the aarch64 parity result is ISA-specific.
2. NOPM sweep with HammerDB, **repeats before breadth**.
3. `num_timed`/`num_requested`, `%util` alongside wait events at VU32 and top VU.
