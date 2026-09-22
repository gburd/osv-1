#!/bin/bash
# Launch the three boxes: BUILDER (builds the OSv image), DRV (pgbench driver),
# LINUX (the Linux native arm).  The OSv target box is launched after the AMI exists.
# Capacity measured 2026-09-21: c6id.*/m6id.12xl exhausted in all 3 us-east-2 AZs;
# m5d.8xlarge and c5d.9xlarge available.  So: builder = c5d.9xlarge (local NVMe for /work),
# driver = c5d.9xlarge (36 vCPU headroom), arms = m5d.8xlarge.
set -uo pipefail
. /home/gburd/ws/osv/.local/bench24/env.sh

echo "=== launch BUILDER c5d.9xlarge (AL2023) ==="
BID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_AL --instance-type c5d.9xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=150,VolumeType=gp3,Iops=6000,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "BUILDERID=$BID"

echo "=== launch DRV c5d.9xlarge (Ubuntu 24.04) ==="
DID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type c5d.9xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "DRVID=$DID"

echo "=== launch LINUX arm m5d.8xlarge (Ubuntu 24.04) ==="
LID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type m5d.8xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "LINUXID=$LID"

aws ec2 wait instance-running --region $REGION --instance-ids $BID $DID $LID

q() { aws ec2 describe-instances --region $REGION --instance-ids "$1" \
        --query "Reservations[0].Instances[0].$2" --output text; }

cat > "$NB/env.boxes" <<EOF
BUILDERID=$BID
DRVID=$DID
LINUXID=$LID
BUILDER=ec2-user@$(q $BID PublicIpAddress)
DRV=ubuntu@$(q $DID PublicIpAddress)
DRVPRIV=$(q $DID PrivateIpAddress)
LINUX=ubuntu@$(q $LID PublicIpAddress)
LINUXPRIV=$(q $LID PrivateIpAddress)
EOF
cat "$NB/env.boxes"
echo LAUNCH_DONE
