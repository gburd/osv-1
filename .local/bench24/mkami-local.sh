#!/bin/bash
# LOCAL-side AMI maker: the builder has no AWS credentials, so the volume
# lifecycle is driven from here and only the dd runs on the builder.
# ARGS: <suffix> <cmdline>
set -uo pipefail
. /home/gburd/ws/osv/.local/bench24/env.sh
SUF="$1"; CMDLINE="$2"

AZ=$(aws ec2 describe-instances --region $REGION --instance-ids $BUILDERID \
  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text)
echo "AZ=$AZ"

echo "=== stamp cmdline into a working copy on the builder ==="
ssh $SSHO $BUILDER "bash -s" <<EOS
set -e
sudo cp /work/osv/build/release.x64/bare.raw /work/img-$SUF.raw
sudo chown ec2-user:ec2-user /work/img-$SUF.raw
truncate -s 2G /work/img-$SUF.raw
python3 - "/work/img-$SUF.raw" '$CMDLINE' <<'PY'
import sys
f=open(sys.argv[1],"r+b")
f.seek(512); f.write(b"\x00"*512)
f.seek(512); f.write(sys.argv[2].encode()+b"\0")
f.seek(512); print("CMDLINE_READBACK:", f.read(1200).split(b"\0")[0].decode())
PY
EOS

VOL=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --size 2 --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Owner,Value=agent-bench24}]' \
  --query VolumeId --output text) || exit 1
echo "VOL=$VOL"
aws ec2 wait volume-available --region $REGION --volume-ids $VOL
aws ec2 attach-volume --region $REGION --volume-id $VOL --instance-id $BUILDERID --device /dev/sdf >/dev/null
sleep 15

ssh $SSHO $BUILDER "bash -s" <<EOS
set -e
DEV=\$(lsblk -dn -o NAME,SIZE | awk '\$2=="2G"{print "/dev/"\$1; exit}')
echo "DEV=\$DEV"
[ -n "\$DEV" ] || exit 1
sudo dd if=/work/img-$SUF.raw of=\$DEV bs=1M oflag=direct status=none
sudo sync
sudo dd if=\$DEV of=/tmp/vfy.bin bs=1M count=1 status=none
python3 -c "
f=open('/tmp/vfy.bin','rb'); f.seek(512)
print('ONDISK_CMDLINE:', f.read(1200).split(b'\0')[0].decode())
f.seek(0); mbr=f.read(2); print('ONDISK_MBR_SIG_OK:', mbr!=b'\x00\x00')"
EOS

aws ec2 detach-volume --region $REGION --volume-id $VOL >/dev/null
aws ec2 wait volume-available --region $REGION --volume-ids $VOL
SNAP=$(aws ec2 create-snapshot --region $REGION --volume-id $VOL --description "osv-native-$SUF" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Owner,Value=agent-bench24}]' \
  --query SnapshotId --output text) || exit 1
echo "SNAP=$SNAP"
aws ec2 wait snapshot-completed --region $REGION --snapshot-ids $SNAP
aws ec2 delete-volume --region $REGION --volume-id $VOL >/dev/null
echo "VOL_DELETED=$VOL"

AMI=$(aws ec2 register-image --region $REGION --name "osv-native-$SUF-$(date +%s)" \
  --architecture x86_64 --root-device-name /dev/sda1 --virtualization-type hvm \
  --ena-support --boot-mode legacy-bios \
  --tag-specifications 'ResourceType=image,Tags=[{Key=Owner,Value=agent-bench24}]' \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAP\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query ImageId --output text) || exit 1
echo "AMI=$AMI"
echo "$AMI $SNAP" > "$NB/ami-$SUF.txt"
echo MKAMI_DONE
