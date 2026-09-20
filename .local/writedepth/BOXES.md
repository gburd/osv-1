# writedepth boxes (Owner=agent-writedepth, us-east-2, profile=lava, acct 769093516156)

## STEP 1-3 (isolate discriminator + fix qualify)
- METAL:  i-0179b5abdcea6333b  m5d.metal  us-east-2b  (raw instance-store NVMe passthrough)

## STEP 4 (HammerDB) - launched only if isolate shows a material win
- DRIVER: (not yet launched) c5.4xlarge

Host: Debian 12 ami-0dc1629a58a7d6458, native qemu 7.2 -M pc for boot, fedora:39 container for build.

## UPDATE 22:30Z
- DRIVER: i-0929075f9348808d7  c5.4xlarge  us-east-2b  18.216.187.52 (priv 172.31.31.102)  Owner=agent-writedepth
