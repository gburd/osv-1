#!/bin/bash
#
# Copyright (C) 2026 Greg Burd
#
# This work is open source software, licensed under the terms of the
# BSD license as described in the LICENSE file in the top-level directory.
#
# Build a GPT + EFI System Partition disk image that boots an OSv kernel
# through UEFI firmware.
#
# This is the artifact that both QEMU/AAVMF and a cloud instance's own firmware
# boot from, which is the point: the local test rig and the cloud deployment
# consume the SAME image, so a pass locally is evidence about the cloud path
# rather than about a QEMU convenience.
#
# The kernel goes in as \EFI\BOOT\BOOTAA64.EFI, the removable-media fallback
# path.  It is used deliberately in preference to an NVRAM boot entry, because
# NVRAM variables do not survive being turned into a cloud machine image.
#
# Usage: build-uefi-disk.sh <loader.img> <out.raw> [size-MiB]

set -eu

kernel=${1:?usage: $0 <loader.img> <out.raw> [size-MiB]}
out=${2:?usage: $0 <loader.img> <out.raw> [size-MiB]}
size_mib=${3:-64}

[ -f "$kernel" ] || { echo "$0: no such kernel image: $kernel" >&2; exit 1; }

# Refuse to build a disk from something that is not a PE/COFF EFI image.  A raw
# arm64 Image boots fine under QEMU -kernel and is silently unbootable here;
# catching that at build time is much cheaper than reading "No bootable option"
# on a cloud serial console 10 minutes later.
magic=$(dd if="$kernel" bs=2 count=1 2>/dev/null | od -An -c | tr -d ' \n')
if [ "$magic" != "MZ" ]; then
    echo "$0: $kernel does not start with the PE 'MZ' magic; it is not an EFI image" >&2
    exit 1
fi

kernel_bytes=$(stat --printf %s "$kernel")
# ESP must hold the kernel plus FAT overhead, and FAT32 needs >= 33 MiB.
need_mib=$(( (kernel_bytes / 1048576) + 40 ))
[ "$size_mib" -ge "$need_mib" ] && total_mib=$size_mib || total_mib=$need_mib

esp_start_sector=2048                       # 1 MiB, the conventional alignment
esp_sectors=$(( (total_mib - 2) * 2048 ))   # leave 1 MiB at each end for GPT

rm -f "$out" "$out.esp"
truncate -s "${total_mib}M" "$out"

# GPT with a single ESP.  sfdisk is used rather than parted/sgdisk because it
# is the one of the three present in this environment, and it writes both the
# primary and the backup GPT, which some firmware checks.
sfdisk --quiet --label gpt "$out" <<EOF
start=$esp_start_sector, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI System Partition"
EOF

# Build the filesystem separately and splice it in, so that no loop device or
# root privilege is needed.
truncate -s "$(( esp_sectors * 512 ))" "$out.esp"
mkfs.vfat -F 32 -n OSVESP "$out.esp" >/dev/null
mmd -i "$out.esp" ::/EFI ::/EFI/BOOT
mcopy -i "$out.esp" "$kernel" ::/EFI/BOOT/BOOTAA64.EFI

dd if="$out.esp" of="$out" bs=512 seek="$esp_start_sector" conv=notrunc \
   status=none
rm -f "$out.esp"

echo "$0: wrote $out (${total_mib} MiB, ESP at sector $esp_start_sector)"
echo "$0: \\EFI\\BOOT\\BOOTAA64.EFI = $kernel ($kernel_bytes bytes)"
