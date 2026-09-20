#!/bin/bash
# Launch: METAL m5d.metal (Debian 12) = OSv guest + Ubuntu guest + host instr.
#         DRV   c5.9xlarge (Ubuntu)   = HammerDB 6.0 driver (36 vCPU: VU192 headroom).
# Tags Owner=agent-scale. Writes env.boxes.
set -uo pipefail
. /home/gburd/ws/osv/.local/scale/env.sh
SC=/home/gburd/ws/osv/.local/scale

TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-scale},{Key=Purpose,Value=osv-scale-retest}]'

echo "=== launch METAL m5d.metal ==="
MID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_DEB --instance-type m5d.metal \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=120,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text 2>&1)
echo "METALID=$MID"

echo "=== launch DRV c5.9xlarge ==="
DID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type c5.9xlarge \
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

cat > "$SC/env.boxes" <<EOF
METALID=$MID
DRVID=$DID
METAL=admin@$MIP
DRV=ubuntu@$DIP
METALPRIV=$MPRIV
DRVPRIV=$DPRIV
EOF
echo "=== env.boxes ==="
cat "$SC/env.boxes"
echo LAUNCH_DONE
