#!/bin/bash
# Build a ROFS image containing ONLY the benchmark binary, and patch the OSv
# root volume's SECTOR 1 so the boot cmdline runs it instead of PostgreSQL.
# Runs ON the Linux driver box (which has the OSv tree's gen-rofs-img.py copied
# to it and both volumes attached).  ARG1 = the full OSv cmdline to install.
#
# NO OSv IMAGE BUILD: the stock AMI's kernel already has rofs compiled in
# (fs/vfs/vfs_conf.cc:93) and --mount-fs is a boot option (loader.cc:352), so a
# statically-delivered app needs no kernel change.
set -e
CMDLINE="$1"

echo "=== DEVICE DISCOVERY BY CONTENT, NOT BY NAME ==="
# Names shuffle across attach/detach; a hardcoded device is how a root disk gets
# wiped.  The OSv root is identified by the cmdline already in ITS OWN sector 1,
# and anything with a mounted filesystem is refused outright.
OSVDEV=""; BENCHDEV=""
for d in /dev/nvme*n1 /dev/xvd? /dev/sd?; do
  [ -b "$d" ] || continue
  if lsblk -n -o MOUNTPOINT "$d" 2>/dev/null | grep -q '[^[:space:]]'; then
    echo "  skip $d: has a mounted filesystem"; continue
  fi
  if sudo dd if=$d bs=512 skip=1 count=1 status=none | grep -qa 'preload-zfs-library'; then
    OSVDEV=$d; echo "  OSV_ROOT=$d (carries an OSv cmdline in sector 1)"
  fi
done
# the bench volume is the 1 GiB one we created for this purpose
for d in /dev/nvme*n1 /dev/xvd? /dev/sd?; do
  [ -b "$d" ] || continue
  [ "$d" = "$OSVDEV" ] && continue
  if lsblk -n -o MOUNTPOINT "$d" 2>/dev/null | grep -q '[^[:space:]]'; then continue; fi
  SZ=$(lsblk -bdn -o SIZE "$d")
  if [ "$SZ" -ge 1000000000 ] && [ "$SZ" -le 1200000000 ]; then
    BENCHDEV=$d; echo "  BENCH_VOL=$d (size $SZ)"
  fi
done
[ -n "$OSVDEV" ]   || { echo "FATAL: no unmounted volume carrying an OSv cmdline"; exit 1; }
[ -n "$BENCHDEV" ] || { echo "FATAL: no 1GiB bench volume found"; exit 1; }
lsblk -o NAME,SIZE,MOUNTPOINT

echo "=== BUILD THE ROFS IMAGE (bench binary only) ==="
mkdir -p /tmp/rofsbuild
printf '[manifest]\n/bench: /tmp/bench-musl\n' > /tmp/rofsbuild/manifest
cd /tmp/osvscripts
python3 gen-rofs-img.py -o /tmp/rofsbuild/rofs.img -m /tmp/rofsbuild/manifest
ls -l /tmp/rofsbuild/rofs.img
python3 - <<'PY'
import struct
f=open('/tmp/rofsbuild/rofs.img','rb')
magic,=struct.unpack('<Q', f.read(8))
print("ROFS_MAGIC=0x%X (want 0xDEADBEAD)" % magic)
assert magic==0xDEADBEAD, "gen-rofs-img.py did not produce a ROFS superblock"
print("ROFS_MAGIC_OK")
PY

echo "=== WRITE ROFS TO THE BENCH VOLUME'S PARTITION 1 ==="
# OSv names partitions vblkN.M from the MBR partition table (read_partition_table
# in the nvme driver), so the filesystem must live in a real partition, not at
# LBA 0.  One primary partition starting at sector 2048.
sudo sgdisk --zap-all "$BENCHDEV" >/dev/null 2>&1 || true
sudo dd if=/dev/zero of=$BENCHDEV bs=1M count=4 status=none
printf 'o\nn\np\n1\n2048\n\nw\n' | sudo fdisk "$BENCHDEV" || true
sleep 3
sudo partprobe "$BENCHDEV" 2>/dev/null || true
sleep 2
PART="${BENCHDEV}p1"
[ -b "$PART" ] || PART="${BENCHDEV}1"
[ -b "$PART" ] || { echo "FATAL: partition 1 did not appear on $BENCHDEV"; lsblk; exit 1; }
echo "BENCH_PART=$PART"
sudo dd if=/tmp/rofsbuild/rofs.img of=$PART bs=1M oflag=direct status=none
sudo sync
echo "--- READBACK FROM THE PARTITION, not from the file we wrote ---"
sudo dd if=$PART bs=8 count=1 status=none | python3 -c "
import sys,struct
m,=struct.unpack('<Q',sys.stdin.buffer.read(8))
print('ONDISK_ROFS_MAGIC=0x%X'%m)
assert m==0xDEADBEAD, 'ROFS magic missing from the partition'
print('ONDISK_ROFS_OK')"

echo "=== PATCH SECTOR 1 OF THE OSv ROOT VOLUME ==="
sudo dd if=$OSVDEV bs=512 skip=1 count=4 of=/tmp/sect1.bin status=none
python3 - /tmp/sect1.bin "$CMDLINE" <<'PY'
import sys
p,new=sys.argv[1],sys.argv[2]
b=open(p,'rb').read()
cur=b.split(b'\0')[0].decode()
print("OLD_CMDLINE_LEN",len(cur))
print("OLD_CMDLINE:",cur)
assert "max_files_per_process" in cur, "SHORT READ: refusing to write over a truncated boot line"
assert "/usr/bin/postgres" in cur, "this does not look like the PG image's cmdline"
assert len(new) < 1024, ("exceeds max_cmdline=1024", len(new))
print("NEW_CMDLINE_LEN",len(new))
print("NEW_CMDLINE:",new)
enc=new.encode()
open('/tmp/sect1.new','wb').write(enc+b'\0'*(2048-len(enc)))
PY
# FOUR sectors, zero padded: writing only one leaves the old cmdline's tail
# behind and the arm boots something that is neither line.
sudo dd if=/tmp/sect1.new of=$OSVDEV bs=512 seek=1 count=4 conv=notrunc status=none
sudo sync
echo "--- READBACK FROM THE DEVICE ---"
sudo dd if=$OSVDEV bs=512 skip=1 count=4 status=none | python3 -c "
import sys
s=sys.stdin.buffer.read().split(b'\0')[0].decode()
print('ONDISK_CMDLINE_LEN',len(s))
print('ONDISK_CMDLINE:',s)
assert '/bench' in s, 'bench binary not in the installed cmdline'
assert 'postgres' not in s, 'postgres still in the installed cmdline'
print('ONDISK_CMDLINE_OK')"
echo PREP_DONE
