# OSv NATIVE-BOOT RECIPE — the wall was NOT toolchain drift, it was the wrong raw image

## THE REAL ROOT CAUSE (banked so no agent hits this wall again)
Every prior "native boot triple-faults / empty console / hangs at 'Booting from Hard Disk'"
was caused by building the AMI from `qemu-img convert -O raw usr.img`. That conversion places
the loader ELF at ~LBA 1186, but OSv's 16-bit boot stub (arch/x64/boot16.S) reads the loader
from **LBA 128** (offset 0x10000). So SeaBIOS/boot16 reads ZEROS at LBA 128 -> hang, no console.

USE `build/release.x64/bare.raw` INSTEAD. `bare.raw` is the raw bootable disk OSv already
produces: loader ELF at LBA 128 (offset 0x10000) exactly where boot16 expects it, with the
rofs appended. Proven by:
  - `-kernel loader.elf` in QEMU: boots (kernel fine).
  - `bare.raw` disk-boot in QEMU TCG: "OSv v0.57.0-452 ... Hello from C code" (boots).
  - `usr.img->raw` disk-boot in QEMU TCG: hangs at "Booting from Hard Disk" (loader@LBA128 = zeros).

## TOOLCHAIN (secondary; all 3 booted the KERNEL fine via -kernel, so drift was a red herring)
Winning pin, matches the Aug-11 booting build: fedora:39 + gcc-13.3.1 + binutils-2.40.
  docker run fedora:39 -> dnf install -y "gcc-13.3.1*" "binutils-2.40*"
(fedora:38 gcc13.2.1/ld2.39 also builds; not needed once bare.raw is used.)

## EXACT NATIVE-AMI BUILD STEPS (validated on m5.xlarge Nitro, us-east-2)
Builder: AL2023 (ami-0742fcde83639b335), install docker+git+qemu-img. No KVM on non-metal.

1. Clone gh-fork gburd/osv-1, checkout the fix branch, cherry-pick the 2 nitro fixes:
     git checkout -B fv3 34eca7799            # wip/native-fork-fix tip (v0.57.0-452)
     git cherry-pick c3c0bcde4                # nvme: cap IO queues to MSI-X budget
     git cherry-pick 3437754eb                # ena: program RSS indirection table
   (apps submodule: stock cloudius osv-apps master has native-example; the pinned
    apps commit 57c60798... lives on gburd/osv-apps for the pg18-fork app.)

2. Build inside fedora:39 container (mount repo at /osv):
     dnf install -y "gcc-13.3.1*" "binutils-2.40*"
     python3 scripts/setup.py
     ./scripts/build -j$(nproc) image=<app> fs=<rofs|zfs> [conf_fork=1 conf_zfs=openzfs ...]
   -> produces build/release.x64/bare.raw  (THE bootable image)

3. Set the OSv cmdline at raw offset 512 (NUL-terminated). MUST include serial console for
   EC2 get-console-output to show anything:
     python3 -c 'f=open("bare.raw","r+b");f.seek(512);f.write(b"\x00"*256);f.seek(512);f.write(b"--console=serial <cmdline>\x00")'

4. dd bare.raw onto a fresh gp3 EBS volume (zero the front 8MB first if reusing a volume),
   detach, snapshot, register-image:
     register-image --architecture x86_64 --root-device-name /dev/sda1 --virtualization-type hvm \
       --ena-support --boot-mode legacy-bios \
       --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"SnapshotId":"<snap>","VolumeType":"gp3","DeleteOnTermination":true}}]'

5. Launch native on Nitro (m5.xlarge / m5d.2xlarge). get-console-output --latest.
   HEALTHY boot looks like:
     OSv v0.57.0-452-gde5d9b83
     eth0: 172.31.x.x            <- ENA up
     Booted up in ~158 ms
     Cmdline: /hello
     Hello from C code
   (An app that exits makes the instance cleanly STOP — that's a successful boot, not a fault.
    A triple-faulting loader instead leaves an empty console forever / reboot-loops.)

## STEP-1 PROOF ARTIFACT
ami-0eb88fc1437501d00 (osv-fv3-hello) launched i-0098b1c21972853ad m5.xlarge -> banner+ENA+Hello, clean stop.
