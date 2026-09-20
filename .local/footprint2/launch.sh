#!/bin/bash
# Launch: METAL m5d.metal (Debian 12) OSv guest + host + instrumentation, and DRV c5.4xlarge (Ubuntu) HammerDB driver.
# Tags Owner=agent-footprint2. Writes env.boxes.
set -uo pipefail
. /home/gburd/ws/osv/.local/footprint2/env.sh
FP=/home/gburd/ws/osv/.local/footprint2

TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-footprint2},{Key=Purpose,Value=osv-fork-footprint}]'

echo "=== launch METAL m5d.metal ==="
MID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_DEB --instance-type m5d.metal \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=120,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "METALID=$MID"

echo "=== launch DRV c5.4xlarge ==="
DID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type c5.4xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "DRVID=$DID"

echo "=== wait running ==="
aws ec2 wait instance-running --region $REGION --instance-ids $MID $DID 2>&1

MIP=$(aws ec2 describe-instances --region $REGION --instance-ids $MID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $MID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
DIP=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
DPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat > "$FP/env.boxes" <<EOF
METALID=$MID
DRVID=$DID
METAL=admin@$MIP
DRV=ubuntu@$DIP
METALPRIV=$MPRIV
DRVPRIV=$DPRIV
EOF
echo "=== env.boxes ==="
cat "$FP/env.boxes"
echo LAUNCH_DONE
