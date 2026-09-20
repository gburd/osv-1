# Leak-hunt box

- **METAL: `i-0dc1686c0531c83b0`** m5d.metal, us-east-2, AWS acct 769093516156 (lava profile), Owner=agent-leakhunt
- AMI: ami-0dc1629a58a7d6458 (Debian 12), key osv-lava, SG sg-0a954e440478e063d (osv-bench)
- Purpose: reproduce + name the OSv forked-backend churn wedge/leak (169k->0 NOPM within one boot)
- Substrate: native qemu 7.2 -M pc, raw NVMe passthrough (cache=none aio=native), 32vCPU/32-64GiB guest

## TERMINATED 2026-09-16: instance i-0dc1686c0531c83b0 -> terminated; volume vol-096413afaa7192442
## (DeleteOnTermination=true) auto-deleted. 0 tagged instances (live), 0 tagged volumes. CONFIRMED.
