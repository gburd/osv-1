# mala AWS scaffold (migrated from chiuso 2026-08-27, chiuso expires 17:11 UTC)
AWS_PROFILE=mala | account 724081032357 | user mala | us-east-2
keypair: osv-rxval (imported, ~/.ssh/osv-rxval)
SG osv-bench: sg-048169877ac87df8d (SSH from 100.56.19.234/32 + all-internal 172.31.0.0/16)
VPC vpc-026fcb0a9dd6a2774 | subnet 2a subnet-00467bcd74f3105bb
AMIs (public, same IDs): AL2023 builder ami-06475e8f54266e38e | Ubuntu noble ami-0dc6aa44dbcdd872e

QUOTA: mala standard on-demand = 32 vCPU (chiuso was 192). m5d.metal (96) EXCEEDS quota.
Requested increase to 192 (pending). Until granted: use m5d.4xlarge (16 vCPU) boxes, one/two at a time.
Build slower on 16 cores (~40-50min) vs 96. Reuse boxes; don't run build+DB+driver+FC concurrently (would exceed 32).
