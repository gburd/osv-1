#!/bin/bash
# THREE ARMS, ONE SOURCE, ONE INSTANCE TYPE (m5d.8xlarge, 32 vCPU, native
# non-metal Nitro):
#   OSv+musl      -- booted from the stock AMI, bench delivered as a ROFS volume
#   Linux+glibc   -- same instance type, same -O2 flags
#   Linux+musl    -- same instance type, same -O2 flags, SAME libc as the OSv arm
# The third arm is what separates "OSv's allocator" from "musl's allocator".
#
# NO OSv IMAGE BUILD.  NO `| tail`.  NO `>/dev/null 2>&1 || true`.
# The EXIT trap terminates everything it created, on every path including failure.
set -u
. /home/gburd/ws/osv/.local/alloc/env.sh
mkdir -p "$NB/raw"
L="$NB/run.log"
exec > >(tee -a "$L") 2>&1
F="$NB/FINDINGS.txt"      # append-only: survives a dead harness
say(){ echo "$*"; echo "$*" >> "$F"; }
say "=== RUN START $(date -u +%FT%TZ) ==="

CREATED=""
VOLS=""
cleanup() {
  rc=$?
  say "=== CLEANUP (exit=$rc) $(date -u +%FT%TZ) ==="
  if [ -n "$CREATED" ]; then
    aws ec2 terminate-instances --region $REGION --instance-ids $CREATED --output text
    aws ec2 wait instance-terminated --region $REGION --instance-ids $CREATED
  fi
  # our own extra volumes are NOT root volumes, so nothing deletes them for us
  for v in $VOLS; do
    say "deleting bench volume $v"
    aws ec2 delete-volume --region $REGION --volume-id $v --output text || true
  done
  say "--- ORPHAN CHECK: instances Owner=$OWNER ---"
  aws ec2 describe-instances --region $REGION --filters Name=tag:Owner,Values=$OWNER \
    --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text | tee -a "$F"
  say "--- ORPHAN CHECK: volumes Owner=$OWNER ---"
  aws ec2 describe-volumes --region $REGION --filters Name=tag:Owner,Values=$OWNER \
    --query 'Volumes[].[VolumeId,State,Size]' --output text | tee -a "$F"
  say "--- ORPHAN CHECK: ALL available volumes in region (root-vol leak detector) ---"
  aws ec2 describe-volumes --region $REGION --filters Name=status,Values=available \
    --query 'Volumes[].[VolumeId,Size,CreateTime,Tags[?Key==`Owner`].Value|[0]]' --output text | tee -a "$F"
  MINE=$(aws ec2 describe-volumes --region $REGION \
    --filters Name=status,Values=available Name=tag:Owner,Values=$OWNER \
    --query 'Volumes[].VolumeId' --output text)
  for v in $MINE; do say "deleting leaked own volume $v"; aws ec2 delete-volume --region $REGION --volume-id $v --output text; done
  say "=== CLEANUP DONE $(date -u +%FT%TZ) ==="
}
trap cleanup EXIT INT TERM

mk(){ aws ec2 run-instances --region $REGION --image-id $1 --instance-type $2 \
        --key-name $KEY --security-group-ids $SG --subnet-id $3 \
        --tag-specifications "$TAGSPEC" "$VOLTAG" \
        --query 'Instances[0].InstanceId' --output text 2>/dev/null; }
q(){ aws ec2 describe-instances --region $REGION --instance-ids "$1" \
       --query "Reservations[0].Instances[0].$2" --output text; }

# ---- AZ DISCOVERY, NOT ASSUMPTION.  m5d.8xlarge was exhausted in 2a AND 2b. ----
SID=""; USEAZ=""; USESUB=""
for pair in "us-east-2c subnet-0852bcf2833df76ef" "us-east-2b subnet-09c88ac2e5d1da3f6" "us-east-2a subnet-04a66ccb68b2a2f13"; do
  set -- $pair
  echo "--- trying OSv arm m5d.8xlarge in $1"
  SID=$(mk $AMI_STOCK m5d.8xlarge $2)
  if [ -n "$SID" ] && [ "$SID" != "None" ]; then USEAZ=$1; USESUB=$2; break; fi
done
[ -n "$SID" ] && [ "$SID" != "None" ] || { echo "FATAL: no m5d.8xlarge capacity in any AZ"; exit 1; }
say "OSV_BOX=$SID AZ=$USEAZ"; CREATED="$SID"

# The Linux arm is the SAME INSTANCE TYPE so the hardware matches exactly, and it
# doubles as the driver/builder box (it has the compilers and does the volume work).
LID=$(mk $AMI_UBU m5d.8xlarge $USESUB)
[ -n "$LID" ] && [ "$LID" != "None" ] || { echo "FATAL: no m5d.8xlarge for the Linux arm in $USEAZ"; exit 1; }
say "LINUX_BOX=$LID"; CREATED="$CREATED $LID"
{ echo "SID=$SID"; echo "LID=$LID"; echo "USEAZ=$USEAZ"; } > "$NB/env.boxes"

aws ec2 wait instance-running --region $REGION --instance-ids $SID $LID
LIP=$(q $LID PublicIpAddress); LX="ubuntu@$LIP"
say "LINUX_IP=$LIP"; echo "LX=$LX" >> "$NB/env.boxes"
say "BOXES_UP $(date -u +%FT%TZ)"

SSHOK=0
for i in $(seq 1 40); do ssh $SSHO $LX true && { SSHOK=1; break; }; sleep 10; done
[ $SSHOK = 1 ] || { echo "FATAL: linux box ssh never came up"; exit 1; }

# ---- build all three binaries from the one source, on the Linux box ----
scp $SSHO "$NB/bench-alloc.c" $LX:/tmp/bench-alloc.c
scp $SSHO "$NB/remote-drvprep.sh" "$NB/remote-prep.sh" $LX:/tmp/
ssh $SSHO $LX "mkdir -p /tmp/osvscripts"
scp $SSHO /home/gburd/ws/osv/scripts/gen-rofs-img.py \
          /home/gburd/ws/osv/scripts/manifest_common.py $LX:/tmp/osvscripts/
ssh $SSHO $LX "bash /tmp/remote-drvprep.sh"; PREPRC=$?
ssh $SSHO $LX "cat /tmp/drvprep.log" > "$NB/raw/drvprep.log"
say "DRVPREP_RC=$PREPRC"
grep -E "DRVPREP_DONE|SELFCHECK_|CPUCLOCK_OK|^FLAGS=|ELF|error" "$NB/raw/drvprep.log" | tee -a "$F"
grep -q DRVPREP_DONE "$NB/raw/drvprep.log" || { echo "FATAL: driver prep failed"; exit 1; }

# =============================== ARM 2 + 3: LINUX ==============================
# Run the Linux arms FIRST: they need no volume surgery, so if the OSv delivery
# fails we still have two of the three arms rather than none.
NPAIRS=20000000     # fixed work per worker; ~0.4 s of CPU at 20 ns/pair
REPS=5
say "=== LINUX ARMS: glibc and musl, n=$NPAIRS reps=$REPS $(date -u +%FT%TZ) ==="
ssh $SSHO $LX "nproc; grep -m1 'model name' /proc/cpuinfo; uname -r" > "$NB/raw/linux-sysinfo.txt" 2>&1
cat "$NB/raw/linux-sysinfo.txt" | tee -a "$F"
for arm in glibc musl-linux; do
  say "--- linux arm $arm START $(date -u +%FT%TZ)"
  ssh $SSHO $LX "/tmp/bench-$arm -C -A -n $NPAIRS -r $REPS" \
      > "$NB/raw/linux-$arm.out" 2> "$NB/raw/linux-$arm.err"
  say "--- linux arm $arm RC=$? $(date -u +%FT%TZ)"
  grep -cE "^RESULT" "$NB/raw/linux-$arm.out" | xargs -I{} say "   $arm RESULT lines: {}"
  grep -E "SELFCHECK_|BENCH_DONE" "$NB/raw/linux-$arm.out" | tee -a "$F"
done

# ================================= ARM 1: OSv =================================
# Deliver the bench binary as a ROFS filesystem on a SECOND volume, and rewrite
# the OSv root's sector-1 cmdline to mount it and run the binary.  No image build.
say "=== OSv ARM PREP $(date -u +%FT%TZ) ==="
BV=$(aws ec2 create-volume --region $REGION --availability-zone $USEAZ --size 1 \
      --volume-type gp3 --tag-specifications "$VOLTAG" --query VolumeId --output text)
[ -n "$BV" ] && [ "$BV" != "None" ] || { echo "FATAL: could not create bench volume"; exit 1; }
VOLS="$BV"; say "BENCH_VOL=$BV"
aws ec2 wait volume-available --region $REGION --volume-ids $BV

ROOT=$(aws ec2 describe-instances --region $REGION --instance-ids $SID \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' --output text)
[ -n "$ROOT" ] && [ "$ROOT" != "None" ] || { echo "FATAL: no OSv root volume"; exit 1; }
say "OSV_ROOTVOL=$ROOT"

aws ec2 stop-instances --region $REGION --instance-ids $SID --output text
aws ec2 wait instance-stopped --region $REGION --instance-ids $SID
aws ec2 detach-volume --region $REGION --volume-id $ROOT --output text
aws ec2 wait volume-available --region $REGION --volume-ids $ROOT
aws ec2 attach-volume --region $REGION --volume-id $ROOT --instance-id $LID --device /dev/sdp --output text
aws ec2 attach-volume --region $REGION --volume-id $BV   --instance-id $LID --device /dev/sdq --output text
sleep 30

# --rootfs=ramfs: do NOT auto-discover/mount ZFS (the PG data pool is irrelevant
# here and mounting it only adds boot time and failure modes).
# --mount-fs=rofs,/dev/vblk1.1,/bm : partition 1 of the SECOND disk.
OSVCMD="--console=serial --nomount --rootfs=ramfs --mount-fs=rofs,/dev/vblk1.1,/bm /bm/bench -C -A -n $NPAIRS -r $REPS"
say "OSV_CMDLINE=$OSVCMD"
ssh $SSHO $LX "sudo bash /tmp/remote-prep.sh '$OSVCMD'" 2>&1 | tee "$NB/raw/osvprep.log"
grep -q PREP_DONE "$NB/raw/osvprep.log" || { echo "FATAL: OSv volume prep failed"; exit 1; }

aws ec2 detach-volume --region $REGION --volume-id $ROOT --output text
aws ec2 detach-volume --region $REGION --volume-id $BV --output text
aws ec2 wait volume-available --region $REGION --volume-ids $ROOT $BV
aws ec2 attach-volume --region $REGION --volume-id $ROOT --instance-id $SID --device /dev/sda1 --output text
aws ec2 attach-volume --region $REGION --volume-id $BV   --instance-id $SID --device /dev/sdb --output text
sleep 15
# *** KNOWN LEAK ROOT CAUSE: re-attaching a root volume RESETS
# DeleteOnTermination to false, so termination leaks it.  Re-set it. ***
aws ec2 modify-instance-attribute --region $REGION --instance-id $SID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"DeleteOnTermination":true}}]'
say "DOT_ROOT_AFTER_REATTACH=$(aws ec2 describe-instances --region $REGION --instance-ids $SID \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.DeleteOnTermination' --output text)"
# and the bench volume too, so it cannot outlive the box either
aws ec2 modify-instance-attribute --region $REGION --instance-id $SID \
  --block-device-mappings '[{"DeviceName":"/dev/sdb","Ebs":{"DeleteOnTermination":true}}]'
say "DOT_BENCH_AFTER_ATTACH=$(aws ec2 describe-instances --region $REGION --instance-ids $SID \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sdb`].Ebs.DeleteOnTermination' --output text)"

say "=== OSv ARM BOOT $(date -u +%FT%TZ) ==="
aws ec2 start-instances --region $REGION --instance-ids $SID --output text
aws ec2 wait instance-running --region $REGION --instance-ids $SID
BOOT_T=$(date +%s)
say "OSV_RUNNING_AT $(date -u +%FT%TZ)"

# The OSv arm has no sshd: its ONLY output channel is the serial console.
for i in $(seq 1 40); do
  sleep 30
  aws ec2 get-console-output --region $REGION --instance-id $SID --latest --output text \
    > "$NB/raw/osv-console-$i.txt"
  N=$(grep -cE "^RESULT" "$NB/raw/osv-console-$i.txt")
  echo "poll $i ($(( $(date +%s) - BOOT_T ))s): $(wc -l < "$NB/raw/osv-console-$i.txt") console lines, $N RESULT lines"
  if grep -q "BENCH_DONE" "$NB/raw/osv-console-$i.txt"; then say "OSV_BENCH_DONE at $(( $(date +%s) - BOOT_T ))s"; break; fi
  if grep -qE "Aborted|panic|page fault|FATAL" "$NB/raw/osv-console-$i.txt"; then
    say "OSV ABORTED/PANICKED - capturing and stopping the poll"; break
  fi
done
cp "$NB/raw/osv-console-$i.txt" "$NB/raw/osv-console-final.txt"
say "--- OSv console: boot + result lines ---"
grep -E "^BENCH_START|^SELFCHECK|^RESULT|^PBIN|^BENCH_DONE|rofs|Aborted|panic|page fault|failed to mount" \
  "$NB/raw/osv-console-final.txt" | tee -a "$F"

say "=== ALL ARMS COMPLETE $(date -u +%FT%TZ) ==="
for f in "$NB/raw/linux-glibc.out" "$NB/raw/linux-musl-linux.out" "$NB/raw/osv-console-final.txt"; do
  say "$(basename $f): $(grep -cE '^RESULT' "$f" 2>/dev/null) RESULT lines"
done
