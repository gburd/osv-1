# CORRECTION: the ZIL coalescing fix was ALREADY in the benchmark base. Today's 43,510 had it.

I concluded earlier "today's 43,510 was measured WITHOUT the ZIL coalescing fix" by checking
`git merge-base --is-ancestor 6d93cb7c5 cbbf74e7` and getting NO. **That check was against the wrong
commit hash.** The fix reached `cbbf74e7` by a different route:

    7f080f25c  zfs: nanosecond-precise cv_timedwait_hires so ZIL commits coalesce on OSv
    1dc86f42c  zfs(openzfs): fix wall-clock vs uptime mismatch in cv_timedwait_hires deadline

`cbbf74e7:bsd/porting/netport1.cc` contains `openzfs_cv_timedwait_hires()` using **`osv::clock::wall`**,
which correctly matches `gethrtime()` = `CLOCK_UPTIME` = `CLOCK_REALTIME` on OSv. The follow-up
`1dc86f42c` had already fixed the exact wall-vs-uptime bug I "re-derived" from scratch today.

## What this means, stated plainly
1. **Today's VU8 = 43,510 was measured WITH a correct ZIL coalescing fix.** So ZIL commit batching is
   NOT the explanation for the 4.9x level gap - or if it is, the fix as implemented does not close it.
   Either way, my "component 1 is unfixed, file #1505 and re-measure" plan was built on a false premise.
2. **#1505 is not a new fix. It is the SAME fix re-plumbed for master's `modules/open_zfs/osv/` layout.**
   Master (0e34e4dc2) genuinely does NOT have it - the `osv/` SPL header on master still tick-converts
   (verified: `cv_timedwait_hires` body divides by `1e9/hz`). So #1505 is a REAL and correct
   master-facing PR: it ports a fix that exists on my integration branches but never reached upstream.
   The value claim in the PR must be softened - I have NOT shown it moves the number, and on the one
   base where I have a number, an equivalent fix was already present and the number was still 4.9x behind.
3. **The A/B I was about to run is now MORE valuable, not less.** OSV_ZFS_HIRES_CV=0 vs =1 on the proven
   base directly answers: does honouring the sub-tick ZIL window actually change throughput, or was the
   whole ZIL-coalescing hypothesis a red herring for the LEVEL gap? Either result is publishable.

## Corrected next step
The A/B is unchanged and still worth running, but its FRAMING flips: it is now a test of whether the
ZIL fix (already in cbbf74e7) matters at all, by toggling it OFF. If OFF tanks throughput, the fix is
load-bearing and #1505 carries real value to master. If OFF changes nothing, ZIL coalescing is not the
level gap and the 3.81 ms/tx lives elsewhere (WAL write path, virtio-blk flush cost, ZFS write
amplification) - and I must go find it rather than assume.

## The honesty note for #1505
I will add a comment to #1505 stating: the fix is correct and master lacks it, but I have NOT
demonstrated a throughput delta; on the base where I have measured, an equivalent fix was already
present and did not by itself reach Linux parity. The A/B numbers will follow.
