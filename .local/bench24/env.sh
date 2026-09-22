export AWS_PROFILE=hotdog AWS_DEFAULT_REGION=us-east-2
REGION=us-east-2
K=/home/gburd/.ssh/osv-hotdog
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-hotdog
SG=sg-0a0fec26afe57cd43
SUBNET=subnet-04a66ccb68b2a2f13
AMI_AL=ami-0f18589f7b30835ef
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-bench24
NB=/home/gburd/ws/osv/.local/bench24
TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-bench24},{Key=Purpose,Value=osv-bench24-aligned-base}]'
VOLTAG='ResourceType=volume,Tags=[{Key=Owner,Value=agent-bench24}]'
SNAPTAG='ResourceType=snapshot,Tags=[{Key=Owner,Value=agent-bench24}]'
IMGTAG='ResourceType=image,Tags=[{Key=Owner,Value=agent-bench24}]'
WANT_SHA=e83cdfef16b639e8e06c3aeeb239491ed43c7096
[ -f "$NB/env.boxes" ] && . "$NB/env.boxes"
true
