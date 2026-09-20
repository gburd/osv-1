# RX-POOL-RESULT (agent osv-rxval) — validate the RX-inline mbuf-pool completion

Instance: **i-01175ac6bd8c9c4cf** (m5d.metal us-east-2, subnet-2a, tag osv-rxval-host).
AWS_PROFILE=chiuso acct 187887018457. Launched (STEP 1 build in progress).
Branch under test: gh-fork **wip/pg-rx-pool @ c6b621300** (2 commits on wip/pg-rx-inline @ b318d8502).

## SCOPE
BUILD + VALIDATE + MEASURE only (code already done+pushed). The gate: the 128x20 heavy
stress that crashed the b318d8502 prototype (assert(preemptable) via m_gethdr->malloc in
IRQ ctx) MUST now survive 0-crash with the per-rxq pre-alloc mbuf-header pool.

## STATUS
- [ ] STEP 1 build rc
- [ ] STEP 2 128x20 heavy 0-crash gate
- [ ] STEP 3 A/B payoff (ctx-sw/query, do_idle%, RO)
- [ ] STEP 4 verdict + cleanup

(updated live below as results land)
