# STEP 2 recycle decomposition - wake2ent is a large, GROWING chunk (lever b confirmed)

Baseline, t8/16/32, correct build with ZILCOMMIT + ZILWAKE2 probes.

| thr | issue_gap us | svc (device write) us | wake2ent (wake->next-committer entry) us | c2i (entry->issue) us | committers_max | itx/lwb mean | op/s |
|-----|-------------|-----------------------|------------------------------------------|-----------------------|----------------|--------------|------|
|  8  | 303         | 188                   | **62**                                   | 15                    | 1              | 6.8          | 12154 |
| 16  | 270         | 196                   | **77**                                   | 29                    | 1              | 9.6          | 19301 |
| 32  | 309         | 207                   | **131**                                  | 65                    | 1              | 16.7         | 30039 |

## The loop input decomposed (parent's discriminating question answered):
The ~285-310us recycle is: device write-service ~195us (lever a) + the wake+reschedule of the next
committer ~62-131us (lever b) + fast async issue (c2i, overlaps). wake2ent is the time from
zil_lwb_flush_vdevs_done waking a committer-waiter (cv_broadcast) to that woken backend actually being
scheduled onto a CPU and ENTERING zil_commit_writer as the next committer.

**wake2ent is 62us -> 77us -> 131us as threads rise 8 -> 16 -> 32.** This is the OSv-specific cross-vCPU
wake cost (IPI to a halted vCPU + reschedule), and CRUCIALLY it GROWS with concurrency - which is
exactly why OSv depth stays flat while Linux (cheap inline/softirq wake) scales to ~13 in flight. At t32
the wake alone is 131us on top of the ~195us device write: nearly HALF the recycle is OSv wake latency.

## Upstream-faithful fix (NO dedicated issuer; upstream has none): shrink wake2ent.
The next committer is woken by cv_broadcast in zil_commit_waiter_done (called from
zil_lwb_flush_vdevs_done on the completion path).  If that wake lands on a halted vCPU it costs an IPI +
reschedule; at higher thread counts more waiters contend and the woken thread waits longer to run.
Cutting wake2ent from ~130us toward single-digit us would shorten the recycle, let backends cycle back
into zil_commit faster, and raise concurrent-in-flight lwbs at the SAME device service - the loop input
to shrink, upstream-faithful (same single-committer-in-caller model as Linux).

Candidate (env-gated OSV_ZIL_DEPTH): make the completion-path wake of the next committer cheaper/faster
- e.g. wake the waiter directly on the completing CPU / avoid the cross-vCPU IPI-to-halted-vCPU, or
prioritize the woken committer so it is scheduled promptly.  A/B: depth must rise toward ~10 and
wake2ent must drop.  This ties to the same OSv scheduler wake cost measured elsewhere (idle-spin / direct
wake).  If shrinking wake2ent raises depth -> upstream-faithful win.  If it cannot (the 195us device
write floor dominates), the write path is the residual and we say so.
