#!/bin/bash
# Launch one box. ARGS: <name> <type> <ami> <root-gb>
. /home/gburd/ws/osv/.local/a2abench7/env.sh
NAME="$1"; TYPE="$2"; AMI="$3"; GB="${4:-100}"
aws ec2 run-instances --image-id "$AMI" --instance-type "$TYPE" --key-name "$KEY" \
  --security-group-ids "$SG" --subnet-id "$SUBNET" --associate-public-ip-address \
  --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":$GB,\"VolumeType\":\"gp3\",\"Iops\":6000,\"Throughput\":500,\"DeleteOnTermination\":true}}]" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Owner,Value=$OWNER},{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text
