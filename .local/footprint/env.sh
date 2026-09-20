export AWS_PROFILE=hotdog AWS_DEFAULT_REGION=us-east-2
REGION=us-east-2
K=/home/gburd/.ssh/osv-hotdog
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-hotdog
SG=sg-0a0fec26afe57cd43
SUBNET=subnet-04a66ccb68b2a2f13
AMI_DEB=ami-0dc1629a58a7d6458
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-footprint
FP=/home/gburd/ws/osv/.local/footprint
[ -f "$FP/env.boxes" ] && . "$FP/env.boxes"
