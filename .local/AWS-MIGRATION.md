# AWS Burner Account Migration: numa -> ouch

## Deadline
- `numa` account AUTO-TERMINATES 2026-07-26T22:20:50Z (all EC2 + EBS die with it).
- Each burner lives 7 days from activation.
- Next account = "ouch" (watch for AWS_PROFILE=ouch to become usable).

## Assets collected LOCALLY (survive account death - safe on floki)
- CODE: all pushed to github.com/gburd/osv-1 (combined branch integ/pg-fork-zfs @ 3f20fef46; all PR branches). Nothing on EC2 was unpushed.
- .local/ozfs-fixes/: 16 bundles + 18 reports (all the fix work + benchmark reports pg-bench-fc.txt/results-*.tsv).
- .local/ec2-assets/: osv-bench-scripts.tgz + osv-bench-fc-assets.tgz = the raidz/serve/tap-net scripts + fc-run.py (the multi-drive Firecracker runner - stock firecracker.py only does 1 drive; DON'T lose this) + Linux baseline results (raw-linux-hp*.log, results.tsv).
- The OSv image (loader.elf/usr.img) is NOT copied - REBUILDABLE from integ/pg-fork-zfs (recipe in the scripts + .local/ozfs-fixes/pg-raidz.txt / pg-zfs-validate.txt).

## What was on the terminated EC2 (numa) - all reproducible
- osv-bench (m5d.metal): Linux baseline done (~115k NOPM), combined image built. Scripts collected.
- osv-bench-kvm / osv-bench-fc (m5d.metal): OSv KVM/FC boxes - raidz built, image pulled, both hit the multi-backend catalog-read coherence wall (no NOPM). Scripts (fc-run.py) collected.
- 3 driver instances (c5.x) - terminated.
- 12x 200GB EBS (osv-bench*-ebs-*) - deleting as instances terminate; die with account anyway.

## To resume on "ouch" (when available)
1. Re-run the one-time setup on ouch: keypair osv-ec2 (~/.ssh/osv-ec2.pem may need re-import or recreate), a security group (SSH from my egress IP + intra-subnet 5432), a subnet in an AZ with m5d.metal. AMI: AL2023 x64 (find the current ami-* in ouch's region; the numa one was ami-03499a87bbb39a09a in us-east-2).
2. THE GATE before any benchmark: fix the multi-backend catalog-read coherence wall (post-fork MAP_SHARED-across-backends: sibling backend reads shared catalog/relcache page as zero). Being fixed on floki NOW - hypervisor-independent, so fixable + testable LOCALLY on floki (KVM+qemw+gdb) WITHOUT any EC2. Only the final benchmark needs EC2/metal.
3. Rebuild the OSv image from integ/pg-fork-zfs, re-create the raidz (scripts in .local/ec2-assets), re-run the matrix (launch all 4 configs parallel from the start this time).

## Key point
The FIX (coherence wall) needs NO EC2 - it's local floki gdb work. Only re-benchmarking needs the new burner. So account death does NOT block progress.

## OUCH ACCOUNT - SET UP (ready for re-benchmark) 2026-07-26
- Account: 266294231451, region us-east-2. AWS_PROFILE=ouch.
- Keypair: osv-ec2 (imported my existing pubkey; ~/.ssh/osv-ec2.pem works).
- SG: sg-0f71bed6221459cc0 (osv-bench-sg): SSH from 73.4.58.126/32 + intra-SG 5432. UPDATE the SSH cidr when my egress IP rotates.
- VPC: vpc-009acbfae7e48930a. m5d.metal AZ: us-east-2c. Subnet: subnet-0b1893bd4bb0bdde2.
- AL2023 x64 AMI: ami-02fff5bd7ef4d2855 (SSM-latest as of 07-26).
- To launch: AWS_PROFILE=ouch, --image-id ami-02fff5bd7ef4d2855 --instance-type m5d.metal --key-name osv-ec2 --security-group-ids sg-0f71bed6221459cc0 --subnet-id subnet-0b1893bd4bb0bdde2 --metadata-options HttpTokens=required,HttpEndpoint=enabled --associate-public-ip-address.
