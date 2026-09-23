#!/bin/bash
# OSv ARM, ATTEMPT 3.  Attempt 2 installed the RIGHT cmdline and still failed,
# and the console said exactly why:
#     failed to mount rofs, error = No such device or address
#     Failed to load object: /bm/bench. Powering off.
# The device PATH was wrong, not the mechanism.  /dev/vblk1 on an m5d is the
# INSTANCE-STORE NVMe SSD, not my EBS volume -- the stock PG image's own cmdline
# proves it, since it builds its ZFS pool on `/dev/vblk1` as scratch.  OSv names
# disks vblk0,1,2... in driver enumeration order (drivers/nvme.cc:157), and
# m5d.8xlarge has TWO instance-store SSDs, so my EBS volume is further down.
#
# FIX WITHOUT GUESSING A SINGLE INDEX: --mount-fs is a REPEATABLE option
# (loader.cc:353 extracts a LIST, fs/vfs/main.cc:2679 mounts each), and a failed
# mount only PRINTS and continues (fs/vfs/main.cc:2632).  So mount every
# candidate index at the SAME mount point /bm: exactly one can succeed, because
# rofs_mount verifies the ROFS magic (fs/rofs/rofs_vfsops.cc:86) and rejects the
# raw instance-store disks and the ZFS root.  The console records which index won.
#
# Reuses the existing boxes/volumes; creates no new ones.  Terminates everything
# and verifies 0 orphans at the end, on every exit path.
set -u
. /home/gburd/ws/osv/.local/alloc/env.sh
. "$NB/env.boxes"
L="$NB/osv3.log"
exec > >(tee -a "$L") 2>&1
F="$NB/FINDINGS.txt"
say(){ echo "$*"; echo "$*" >> "$F"; }
say "=== OSv ATTEMPT 3 START $(date -u +%FT%TZ) ==="

cleanup() {
  rc=$?
  say "=== FINAL CLEANUP (exit=$rc) $(date -u +%FT%TZ) ==="
  aws ec2 terminate-instances --region $REGION --instance-ids $SID $LID --output text || true
  aws ec2 wait instance-terminated --region $REGION --instance-ids $SID $LID || true
  say "--- instances Owner=$OWNER ---"
  aws ec2 describe-instances --region $REGION --filters Name=tag:Owner,Values=$OWNER \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | tee -a "$F"
  say "--- volumes Owner=$OWNER ---"
  aws ec2 describe-volumes --region $REGION --filters Name=tag:Owner,Values=$OWNER \
    --query 'Volumes[].[VolumeId,State,Size]' --output text | tee -a "$F"
  MINE=$(aws ec2 describe-volumes --region $REGION \
    --filters Name=status,Values=available Name=tag:Owner,Values=$OWNER \
    --query 'Volumes[].VolumeId' --output text)
  for v in $MINE; do say "deleting leaked own volume $v"; aws ec2 delete-volume --region $REGION --volume-id $v --output text; done
  say "--- ALL available volumes REGION-WIDE (root-vol leak detector) ---"
  aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,CreateTime,Tags[?Key==`Owner`].Value|[0]]' --output text | tee -a "$F"
  say "=== FINAL CLEANUP DONE $(date -u +%FT%TZ) ==="
}
trap cleanup EXIT INT TERM

q(){ aws ec2 describe-instances --region $REGION --instance-ids "$1" \
       --query "Reservations[0].Instances[0].$2" --output text; }
NPAIRS=20000000
REPS=5
ROOT=$(q $SID 'BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId')
say "ROOT=$ROOT LINUX=$LID STATE=$(q $SID State.Name)"

aws ec2 stop-instances --region $REGION --instance-ids $SID --output text
aws ec2 wait instance-stopped --region $REGION --instance-ids $SID
aws ec2 detach-volume --region $REGION --volume-id $ROOT --output text
aws ec2 wait volume-available --region $REGION --volume-ids $ROOT
aws ec2 attach-volume --region $REGION --volume-id $ROOT --instance-id $LID --device /dev/sdp --output text
sleep 30

MOUNTS=""
for i in 1 2 3 4 5; do MOUNTS="$MOUNTS --mount-fs=rofs,/dev/vblk$i.1,/bm"; done
OSVCMD="--console=serial --noshutdown --rootfs=ramfs$MOUNTS /bm/bench -C -A -n $NPAIRS -r $REPS"
say "OSV_CMDLINE3=$OSVCMD"
say "OSV_CMDLINE3_LEN=${#OSVCMD}"

ssh $SSHO $LX "sudo bash -s" <<EOS 2>&1 | tee "$NB/raw/osvprep3.log"
set -e
DEV=""
for d in /dev/nvme*n1 /dev/xvd? /dev/sd?; do
  [ -b "\$d" ] || continue
  if lsblk -n -o MOUNTPOINT "\$d" 2>/dev/null | grep -q '[^[:space:]]'; then continue; fi
  if dd if=\$d bs=512 skip=1 count=1 status=none | grep -qa '/bm/bench'; then DEV=\$d; fi
done
[ -n "\$DEV" ] || { echo "FATAL: no volume carrying the bench cmdline"; exit 1; }
echo "OSVDEV=\$DEV"
python3 - "\$DEV" '$OSVCMD' <<'PY'
import sys,subprocess
dev,new=sys.argv[1],sys.argv[2]
cur=subprocess.run(["dd","if="+dev,"bs=512","skip=1","count=4","status=none"],
                   capture_output=True).stdout.split(b"\0")[0].decode()
print("OLD:",cur)
assert "/bm/bench" in cur, "not the bench cmdline"
assert len(new) < 1024, ("too long", len(new))
open("/tmp/s3.new","wb").write(new.encode()+b"\0"*(2048-len(new)))
print("NEW:",new)
PY
dd if=/tmp/s3.new of=\$DEV bs=512 seek=1 count=4 conv=notrunc status=none
sync
dd if=\$DEV bs=512 skip=1 count=4 status=none | python3 -c "
import sys
s=sys.stdin.buffer.read().split(b'\0')[0].decode()
print('ONDISK:',s)
assert s.count('--mount-fs=')==5, 'expected 5 mount candidates'
assert '--noshutdown' in s and '/bm/bench' in s
print('ONDISK_OK')"
echo PREP3_DONE
EOS
grep -q PREP3_DONE "$NB/raw/osvprep3.log" || { say "FATAL: attempt-3 patch failed"; exit 1; }

aws ec2 detach-volume --region $REGION --volume-id $ROOT --output text
aws ec2 wait volume-available --region $REGION --volume-ids $ROOT
aws ec2 attach-volume --region $REGION --volume-id $ROOT --instance-id $SID --device /dev/sda1 --output text
sleep 15
aws ec2 modify-instance-attribute --region $REGION --instance-id $SID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"DeleteOnTermination":true}}]'
say "DOT_ROOT=$(q $SID 'BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.DeleteOnTermination')"
say "DOT_BENCH=$(q $SID 'BlockDeviceMappings[?DeviceName==`/dev/sdb`].Ebs.DeleteOnTermination')"

aws ec2 start-instances --region $REGION --instance-ids $SID --output text
aws ec2 wait instance-running --region $REGION --instance-ids $SID
BOOT_T=$(date +%s)
say "OSV_RUNNING3 $(date -u +%FT%TZ)"
# EC2's serial console is published with a multi-minute lag, so poll patiently and
# never treat an empty buffer as a failure.
for i in $(seq 1 60); do
  sleep 30
  aws ec2 get-console-output --region $REGION --instance-id $SID --latest --output text \
    > "$NB/raw/osv3-console-$i.txt" 2>&1
  cp "$NB/raw/osv3-console-$i.txt" "$NB/raw/osv3-console-final.txt"
  N=$(grep -acE "^RESULT" "$NB/raw/osv3-console-$i.txt" || true)
  S=$(q $SID State.Name)
  echo "poll $i ($(( $(date +%s) - BOOT_T ))s, state=$S): $(wc -c < "$NB/raw/osv3-console-$i.txt") bytes, $N RESULT"
  grep -aq "BENCH_DONE" "$NB/raw/osv3-console-$i.txt" && { say "OSV3_BENCH_DONE at $(( $(date +%s) - BOOT_T ))s"; break; }
  grep -aqE "Failed to load object|panic|page fault|Assertion|Aborted" "$NB/raw/osv3-console-$i.txt" && { say "OSV3 FAILED EARLY"; break; }
  [ "$S" = "stopped" ] && { say "OSV3 STOPPED ITSELF at $(( $(date +%s) - BOOT_T ))s"; break; }
done
say "--- OSv attempt 3, mount outcome and results ---"
grep -aE "rofs|failed to mount|^BENCH_START|^SELFCHECK|^RESULT|^PBIN|^BENCH_DONE|Failed to load|Cmdline" \
  "$NB/raw/osv3-console-final.txt" | tee -a "$F"
say "=== OSv ATTEMPT 3 END $(date -u +%FT%TZ) ==="
