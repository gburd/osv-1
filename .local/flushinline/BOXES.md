# flushinline run — box IDs (report FIRST)

Region: us-east-2   Profile: lava (acct 769093516156)   Tag: Owner=agent-flushinline

- METAL (OSv host + isolate + HammerDB SUT): i-00bce9be7b8f34a9f  m5d.metal  us-east-2a
- DRIVER (HammerDB, STEP C only):            i-0dcf2ad4d13a65dd4  c5.4xlarge us-east-2a

Key: ~/.ssh/osv-lava   SG: sg-0a954e440478e063d (osv-bench)   AMI: ami-0dc1629a58a7d6458 (Debian 12)

Branch: gh-fork/bench/flushinline @ ff5b88b9d  (base 7e297fbc2 + 0040 inline-flush patch)
Fix: OSV_ZIL_FLUSH_INLINE=1 (default off) — inline ZIO_TYPE_FLUSH completion on blk thread.

## TERMINATION — DONE (confirmed 0 orphans)
- i-00bce9be7b8f34a9f (metal): terminated
- i-0dcf2ad4d13a65dd4 (driver): terminated
- orphan instances tagged agent-flushinline: 0
- orphan volumes tagged agent-flushinline: 0  (instance-store auto-gone; EBS DeleteOnTermination=true)

## OUTCOME: inline-flush hypothesis REFUTED (measured null). See STEP-B-RESULT.md.
- STEP B done; STEP C (HammerDB) NOT run (gated on flush dropping — it did not).
- No PR filed (fix is a measured null, not an isolate win). Branch pushed for the record.
