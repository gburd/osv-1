# Leak #2 FIX-APPLY box (agent-leak2b)

- **METAL: `i-0d75e6472ec9328ea`** m5d.metal, us-east-2a, AWS acct 769093516156 (lava profile), Owner=agent-leak2b
- AMI: ami-0dc1629a58a7d6458 (Debian 12), key osv-lava (~/.ssh/osv-lava), SG sg-0a954e440478e063d (osv-bench), subnet subnet-0230d1c45d8a098a7
- Launched: fix-apply run for leak #2 (per-fork memory leak). Design DONE (fix_striped.py). Job: APPLY -> BUILD -> VALIDATE (3-way gate) -> BANK.
- Substrate: qemu 7.2 -M pc, raw NVMe passthrough, 32vCPU/32GiB guest. Harness: host-setup.sh/build-image.sh/boot.sh/integ.sh.
- Base: gh-fork bench/leakhunt (leak #1 fd fix + OSV_LEAK_PROBE). Apps pinned 3f93f43.

## STATUS: TERMINATED 2026-09-16 18:35 UTC. instance=terminated, root volume auto-deleted (DeleteOnTermination). 0 orphans confirmed (0 non-terminated agent-leak2b instances, 0 agent-leak2b volumes).

## OUTCOME: fix_striped.py FAILS the 3-way gate (crashes: unikernel RCU-vfs double-free). g_bump top-rewind measured non-viable (8.8%). See RESULT.md. Nothing banked, no PR touched, no branch pushed.

## TERMINATE (was, done):
## aws ec2 terminate-instances --profile lava --region us-east-2 --instance-ids i-0d75e6472ec9328ea
