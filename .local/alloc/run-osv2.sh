#!/bin/bash
# OSv ARM, ATTEMPT 2.  Attempt 1 produced a 47-byte console and a STOPPED
# instance: OSv calls poweroff() once main() returns (loader.cc:844/906), the
# instance stopped itself, and EC2 DISCARDS the serial console buffer of a
# stopped instance -- so the run destroyed its own evidence rather than failing.
#
# FIX: --noshutdown (loader.cc:906 -> wait_until([]{return false;})) keeps the
# kernel alive after main() returns, so the box stays RUNNING and the console
# buffer stays readable.  The binary, the volumes and the flags are UNCHANGED;
# only the shutdown behaviour differs, so the measurement is not affected.
#
# Reuses the boxes and volumes the main run already created; creates nothing.
set -u
. /home/gburd/ws/osv/.local/alloc/env.sh
. "$NB/env.boxes"
L="$NB/osv2.log"
exec > >(tee -a "$L") 2>&1
F="$NB/FINDINGS.txt"
say(){ echo "$*"; echo "$*" >> "$F"; }
say "=== OSv ATTEMPT 2 START $(date -u +%FT%TZ) ==="
q(){ aws ec2 describe-instances --region $REGION --instance-ids "$1" \
       --query "Reservations[0].Instances[0].$2" --output text; }

NPAIRS=20000000
REPS=5
ROOT=$(q $SID 'BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId')
BV=$(q $SID 'BlockDeviceMappings[?DeviceName==`/dev/sdb`].Ebs.VolumeId')
say "ROOT=$ROOT BENCH=$BV STATE=$(q $SID State.Name)"

aws ec2 stop-instances --region $REGION --instance-ids $SID --output text
aws ec2 wait instance-stopped --region $REGION --instance-ids $SID
aws ec2 detach-volume --region $REGION --volume-id $ROOT --output text
aws ec2 wait volume-available --region $REGION --volume-ids $ROOT
aws ec2 attach-volume --region $REGION --volume-id $ROOT --instance-id $LID --device /dev/sdp --output text
sleep 30

# Only ONE change from attempt 1: --noshutdown.
OSVCMD="--console=serial --nomount --noshutdown --rootfs=ramfs --mount-fs=rofs,/dev/vblk1.1,/bm /bm/bench -C -A -n $NPAIRS -r $REPS"
say "OSV_CMDLINE2=$OSVCMD"
ssh $SSHO $LX "sudo bash -s" <<EOS 2>&1 | tee "$NB/raw/osvprep2.log"
set -e
DEV=""
for d in /dev/nvme*n1 /dev/xvd? /dev/sd?; do
  [ -b "\$d" ] || continue
  if lsblk -n -o MOUNTPOINT "\$d" 2>/dev/null | grep -q '[^[:space:]]'; then continue; fi
  if sudo dd if=\$d bs=512 skip=1 count=1 status=none | grep -qa 'mount-fs=rofs'; then DEV=\$d; fi
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
assert "--noshutdown" not in cur, "already patched"
assert len(new) < 1024
open("/tmp/s1.new","wb").write(new.encode()+b"\0"*(2048-len(new)))
print("NEW:",new)
PY
dd if=/tmp/s1.new of=\$DEV bs=512 seek=1 count=4 conv=notrunc status=none
sync
dd if=\$DEV bs=512 skip=1 count=4 status=none | python3 -c "
import sys
s=sys.stdin.buffer.read().split(b'\0')[0].decode()
print('ONDISK:',s)
assert '--noshutdown' in s and '/bm/bench' in s
print('ONDISK_OK')"
echo PREP2_DONE
EOS
grep -q PREP2_DONE "$NB/raw/osvprep2.log" || { say "FATAL: attempt-2 patch failed"; exit 1; }

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
say "OSV_RUNNING2 $(date -u +%FT%TZ)"
for i in $(seq 1 45); do
  sleep 30
  aws ec2 get-console-output --region $REGION --instance-id $SID --latest --output text \
    > "$NB/raw/osv2-console-$i.txt"
  N=$(grep -acE "^RESULT" "$NB/raw/osv2-console-$i.txt" || true)
  S=$(q $SID State.Name)
  echo "poll $i ($(( $(date +%s) - BOOT_T ))s, state=$S): $(wc -l < "$NB/raw/osv2-console-$i.txt") lines, $N RESULT"
  cp "$NB/raw/osv2-console-$i.txt" "$NB/raw/osv2-console-final.txt"
  grep -aq "BENCH_DONE" "$NB/raw/osv2-console-$i.txt" && { say "OSV2_BENCH_DONE at $(( $(date +%s) - BOOT_T ))s"; break; }
  grep -aqE "Aborted|panic|page fault|failed to mount|Assertion" "$NB/raw/osv2-console-$i.txt" && { say "OSV2 FAULTED"; break; }
  [ "$S" = "stopped" ] && { say "OSV2 STOPPED ITSELF at $(( $(date +%s) - BOOT_T ))s"; break; }
done
say "--- OSv attempt 2 console ---"
grep -aE "^BENCH_START|^SELFCHECK|^RESULT|^PBIN|^BENCH_DONE|rofs|Aborted|panic|fault|failed to mount" \
  "$NB/raw/osv2-console-final.txt" | tee -a "$F"
say "=== OSv ATTEMPT 2 END $(date -u +%FT%TZ) ==="
