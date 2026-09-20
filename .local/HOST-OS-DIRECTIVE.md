# EC2 host OS directive (operator, 2026-09-14): NixOS (preferred) > Debian > Fedora. NOT Amazon Linux.

Applies to ALL EC2 test / benchmark / development. Amazon Linux (AL2023) is BANNED as a host.

## Why this directly fixes the substrate problem
The fedora:39-container + qemu 8.1.3 + `-M pc` workaround exists ONLY because AL2023 ships qemu 11,
which cannot boot OSv (AHCI hang under -M q35, PR #1498). Getting off Amazon Linux removes the trap:
on a host we control, we run a native qemu that boots OSv (no container, no -M pc hack) AND have a clean
Firecracker/bare-metal path. This directive and the Firecracker pivot are the same move.

## The choices, resolved against lava's available AMIs (us-east-2)
- **NixOS (preferred):** no ready general AMI on lava (only a stray NocoDB appliance). Proper NixOS-on-EC2
  needs a nixos-images/amazon-image build (a flake) - worth doing for reproducible, pinned
  qemu/firecracker/kernel versions (host-level apples-to-apples), but a setup cost. FOLLOW-UP: build a
  pinned NixOS bench-host flake.
- **Debian 12 (ready fallback, use now):** official Debian AMIs on lava -
    x86_64  ami-0dc1629a58a7d6458  (debian-12-amd64-20260909)
    arm64   ami-03c7a95b4517df9e0  (debian-12-arm64-20260909)
  Ships qemu 7.2 (predates the q35 AHCI regression -> boots OSv NATIVELY, no fedora container, no -M pc)
  and packages firecracker easily. Solves both the "boot OSv" and "test the real substrate" problems.
- **Fedora:** allowed (a recent Fedora ships a modern qemu; would still need -M pc or a boot workaround
  like AL2023 - so LESS preferred than Debian for the OSv-boot case). Use only if Debian is unavailable.

## AMIs to STOP using (Amazon Linux - do not launch)
  AL2023 x86_64 ami-0eff088391f589f50 / ami-0619724297c6fa28d / ami-06475e8f54266e38e
  AL2023 arm64  ami-01c02d0105285e20d
These are all over the harness scripts and prior agent briefs; PURGE them from the recipe.

## Action items
1. Update .local/ROADMAP.md AMI banner: default host = Debian 12 (ami-0dc1629a58a7d6458 x86 /
   ami-03c7a95b4517df9e0 arm), NOT AL2023.
2. Rewrite the benchmark harness host-setup to target Debian 12: install qemu (native, boots OSv - test
   -M pc vs -M q35 on qemu 7.2) OR firecracker, drop the fedora:39 container entirely.
3. Every future benchmark agent brief: launch a DEBIAN host (or NixOS once the flake exists), NEVER
   AL2023. Record host OS + qemu/firecracker version in the run identity block.
4. Build the pinned NixOS bench-host flake as the preferred long-term substrate (reproducible host).

## Note on the driver box
The HammerDB driver box is a pure TCP client - its host OS does not affect the guest-under-test, but for
consistency and the directive, use Debian there too (Ubuntu was used before; acceptable but standardize).
