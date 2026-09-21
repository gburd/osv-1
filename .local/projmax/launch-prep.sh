#!/bin/bash
# Launch BUILDER (c6id.8xlarge AL2023) + DRV (c5.9xlarge Ubuntu24) for the
# projected-max native run. Owner=agent-projmax on everything.
set -uo pipefail
. /home/gburd/ws/osv/.local/projmax/env.sh

BID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_AL --instance-type c6id.8xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=200,VolumeType=gp3,Iops=8000,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "BUILDERID=$BID"

DID=$(aws ec2 run-instances --region $REGION \
  --image-id $AMI_UBU --instance-type c5.9xlarge \
  --key-name $KEY --security-group-ids $SG --subnet-id $SUBNET \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=60,VolumeType=gp3,DeleteOnTermination=true}' \
  --tag-specifications "$TAGSPEC" \
  --query 'Instances[0].InstanceId' --output text) || exit 1
echo "DRVID=$DID"

aws ec2 wait instance-running --region $REGION --instance-ids $BID $DID

BIP=$(aws ec2 describe-instances --region $REGION --instance-ids $BID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
DIP=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
DPRIV=$(aws ec2 describe-instances --region $REGION --instance-ids $DID --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)

cat > "$PM/env.boxes" <<EOF
BUILDERID=$BID
DRVID=$DID
BUILDER=ec2-user@$BIP
DRV=ubuntu@$DIP
DRVPRIV=$DPRIV
EOF
cat "$PM/env.boxes"
echo PREP_LAUNCH_DONE
