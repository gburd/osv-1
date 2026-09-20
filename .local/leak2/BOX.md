# Leak #2 hunt box

- **METAL: `i-063d9d27134f102b1`** m5d.metal, us-east-2, AWS acct 769093516156 (lava profile), Owner=agent-leak2
- AMI: ami-0dc1629a58a7d6458 (Debian 12), key osv-lava (~/.ssh/osv-lava), SG sg-0a954e440478e063d (osv-bench)
- Purpose: root-cause + fix the SECOND OSv forked-backend teardown leak (per-fork MEMORY leak, ~1MB/backend,
  unreclaimable, monotonic mem_free drop -> OOM ~round 280). Leak #1 (fds) already fixed on bench/leakhunt.
- Substrate: native qemu 7.2 -M pc, raw NVMe passthrough (cache=none aio=native), 32vCPU/32GiB guest.
- OSv branch: gh-fork bench/leakhunt (base + OSV_LEAK_PROBE + fd-reap fix ac6a389d2), fd fix ON.

## STATUS: launching (pending). Prior box i-0dc1686c0531c83b0 TERMINATED (no overlap).

## TERMINATE (always, even on failure):
## aws ec2 terminate-instances --profile lava --region us-east-2 --instance-ids i-063d9d27134f102b1
