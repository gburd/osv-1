#!/bin/bash
# Launch the two boxes for the gates run on the hotdog account:
#   METAL: m5d.metal (Debian 12) us-east-2a subnet-04a66ccb68b2a2f13 -- OSv + Ubuntu guests + host + instr
#   DRV:   c5.4xlarge (Ubuntu 24.04) -- HammerDB 6.0 driver
# Tags Owner=agent-gates. Writes env.boxes with the ids + IPs.
set -uo pipefail
. /home/gburd/ws/osv/.local/gates/env.sh
GATES=/home/gburd/ws/osv/.local/gates

TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-gates},{Key=Purpose,Value=osv-gates}]'

echo "=== launch METAL m5d.metal ==="
MID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_DEB --instance-type m5d.metal \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=120,VolumeType=gp3}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "METALID=$MID"

echo "=== launch DRV c5.4xlarge ==="
DID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type c5.4xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=40,VolumeType=gp3}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "DRVID=$DID"

echo "=== wait running ==="
aws ec2 wait instance-running --region $REGION --instance-ids $MID $DID 2>&1

MIP=$(aws ec2 describe-instances --region $REGION --instance-ids $MID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
MPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $MID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
DIP=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
DPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat > "$GATES/env.boxes" <<EOF
METALID=$MID
DRVID=$DID
METAL=admin@$MIP
DRV=ubuntu@$DIP
METALPRIV=$MPRIV
DRVPRIV=$DPRIV
EOF
echo "=== env.boxes ==="
cat "$GATES/env.boxes"
echo LAUNCH_DONE
