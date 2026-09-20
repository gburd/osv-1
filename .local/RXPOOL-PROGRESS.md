# RX-INLINE mbuf-pool completion (osv-rxpool)
Instance: i-06988a375d7f726cd (m5d.metal us-east-2, subnet-2a, tag osv-rxpool-host). AWS_PROFILE=chiuso acct ...457.
Base: gh-fork wip/pg-rx-inline @ b318d8502 (Option-A inline prototype, off-by-default).
GOAL: per-rxq pre-allocated mbuf-header pool so the inline IRQ drain NEVER mallocs.
STATUS: launched 2026-08-20T19:28:47Z
