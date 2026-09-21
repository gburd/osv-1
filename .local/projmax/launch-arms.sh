#!/bin/bash
# Launch the two NATIVE arms on m5d.8xlarge:
#   OSV   - the projected-max OSv image as the instance's ONLY operating system
#   LINUX - Ubuntu 24.04 as the same instance type's own host OS (matched arm)
# m5d.metal is deliberately NOT used: it does not boot OSv (reproduced twice).
set -uo pipefail
. /home/gburd/ws/osv/.local/projmax/env.sh
AMI_OSV="$1"

OID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_OSV --instance-type m5d.8xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "OSVID=$OID"

LID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type m5d.8xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=80,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "LINUXID=$LID"

aws ec2 wait instance-running --region $REGION --instance-ids $OID $LID

OPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $OID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
LPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $LID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
LPUB=$(aws ec2 describe-instances --region $REGION --instance-ids $LID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat >> "$PM/env.boxes" <<EOF
OSVID=$OID
LINUXID=$LID
OSVPRIV=$OPRIV
LINUXPRIV=$LPRIV
LINUX=ubuntu@$LPUB
AMI_OSV=$AMI_OSV
EOF
echo "OSVPRIV=$OPRIV LINUXPRIV=$LPRIV"
echo ARMS_LAUNCHED
