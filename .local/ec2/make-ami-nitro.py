#!/usr/bin/env python3
"""Register an OSv AMI from a locally-built image, Nitro-aware.

Runs ON the builder EC2 instance. Creates an EBS volume, attaches it to this
instance, writes the raw image onto the volume (detecting the NVMe device that
appears, since Nitro ignores the xvdf device name), snapshots it, and registers
an HVM/ENA AMI pointing at the snapshot.

Credentials come from the environment (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
/ AWS_DEFAULT_REGION). Nothing is written to disk.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from urllib.request import Request, urlopen

# Match a whole-namespace block device (nvme0n1) but not the controller
# (nvme0) or a partition (nvme0n1p1).
_NS_RE = re.compile(r"^nvme\d+n\d+$")


def imds(path):
    token = urlopen(Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )).read().decode()
    return urlopen(Request(
        "http://169.254.169.254/latest/meta-data/" + path,
        headers={"X-aws-ec2-metadata-token": token},
    )).read().decode()


def nvme_namespaces():
    return set(p for p in os.listdir("/dev") if _NS_RE.match(p))


def wait_volume(vol, state):
    while vol.state != state:
        time.sleep(1)
        vol.reload()


def image_virtual_size(path):
    info = json.loads(subprocess.check_output(
        ["qemu-img", "info", "--output=json", path]))
    return info["virtual-size"]


def to_gib(nbytes):
    gib = 1 << 30
    return (nbytes + gib - 1) >> 30


def write_cmdline(dev, cmdline):
    """Write OSv's boot cmdline at byte offset 512 as a NUL-terminated string.

    qemu-img convert zeroes this sector, so it must be re-applied directly on
    the raw device. OSv's boot16.S reads one 512-byte sector at LBA 1 into the
    multiboot cmdline; the loader treats it as a C string (NUL-terminated).
    The device is root-owned, so the write goes through `sudo dd`.
    """
    data = cmdline.encode() + b"\0"
    if len(data) > 512:
        raise ValueError(f"cmdline too long for one sector: {len(data)} bytes")
    # dd at seek=512 bytes; conv=notrunc so we patch in place without truncating.
    p = subprocess.Popen(
        ["sudo", "dd", "of=" + dev, "bs=1", "seek=512", "conv=notrunc",
         "status=none"],
        stdin=subprocess.PIPE)
    p.communicate(data)
    if p.returncode != 0:
        raise subprocess.CalledProcessError(p.returncode, "dd")





def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--name", default="osv-postgres-x64")
    ap.add_argument("-i", "--input", default="build/release.x64/usr.img")
    ap.add_argument("-d", "--description", default="OSv PostgreSQL+ZFS x86_64")
    ap.add_argument("-a", "--arch", default="x86_64",
                    choices=["x86_64", "arm64"],
                    help="AMI architecture (arm64 for Graviton)")
    ap.add_argument("-b", "--boot-mode", default=None,
                    choices=["legacy-bios", "uefi"],
                    help="boot mode; default legacy-bios for x86_64, uefi for arm64")
    ap.add_argument("-c", "--cmdline", default=None,
                    help="OSv boot cmdline to write to the raw device after "
                         "conversion; qemu-img convert zeroes the offset-512 "
                         "cmdline sector, so it must be re-applied on-device")
    args = ap.parse_args()

    boot_mode = args.boot_mode
    if boot_mode is None:
        boot_mode = "uefi" if args.arch == "arm64" else "legacy-bios"

    import boto3
    az = imds("placement/availability-zone")
    region = az[:-1]
    instance_id = imds("instance-id")
    ec2 = boto3.resource("ec2", region_name=region)

    vsize = image_virtual_size(args.input)
    gib = max(1, to_gib(vsize))
    print(f"[1/7] Creating {gib} GiB gp3 volume in {az}")
    vol = ec2.create_volume(Size=gib, AvailabilityZone=az, VolumeType="gp3")
    wait_volume(vol, "available")
    print(f"      volume {vol.id} available")

    before = nvme_namespaces()
    print(f"[2/7] Attaching {vol.id} to {instance_id} (device xvdf; Nitro remaps to nvme)")
    vol.attach_to_instance(InstanceId=instance_id, Device="/dev/xvdf")
    dev = None
    for _ in range(120):
        time.sleep(1)
        new = nvme_namespaces() - before
        if new:
            dev = "/dev/" + sorted(new)[0]
            break
    if not dev:
        print("      ERROR: no new NVMe device appeared after attach", file=sys.stderr)
        vol.detach_from_instance()
        wait_volume(vol, "available")
        vol.delete()
        sys.exit(1)
    print(f"      new block device: {dev}")

    print(f"[3/7] Writing raw image {args.input} -> {dev}")
    subprocess.check_call(["sudo", "qemu-img", "convert", "-O", "raw", args.input, dev])
    subprocess.check_call(["sync"])

    if args.cmdline:
        print(f"      re-applying boot cmdline on {dev}: {args.cmdline!r}")
        write_cmdline(dev, args.cmdline)
        subprocess.check_call(["sync"])

    print(f"[4/7] Detaching {vol.id}")
    vol.detach_from_instance()
    wait_volume(vol, "available")

    print(f"[5/7] Creating snapshot from {vol.id}")
    snap = vol.create_snapshot(Description=args.description)
    snap.wait_until_completed()
    print(f"      snapshot {snap.id} completed")

    print(f"[6/7] Deleting volume {vol.id}")
    vol.delete()

    print(f"[7/7] Registering AMI '{args.name}' from {snap.id}")
    ami = ec2.register_image(
        Name=args.name,
        Description=args.description,
        Architecture=args.arch,
        RootDeviceName="/dev/xvda",
        VirtualizationType="hvm",
        EnaSupport=True,
        BootMode=boot_mode,
        BlockDeviceMappings=[{
            "DeviceName": "/dev/xvda",
            "Ebs": {"SnapshotId": snap.id, "DeleteOnTermination": True,
                    "VolumeType": "gp3"},
        }],
    )
    print(f"AMI_ID={ami.id}")


if __name__ == "__main__":
    main()
