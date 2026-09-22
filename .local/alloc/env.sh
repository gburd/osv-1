export AWS_PROFILE=hotdog AWS_DEFAULT_REGION=us-east-2
REGION=us-east-2
K=/home/gburd/.ssh/osv-hotdog
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-hotdog
SG=sg-0a0fec26afe57cd43
AMI_UBU=ami-00adec9774170bad2
AMI_STOCK=ami-0ac424816542c0464
OWNER=agent-alloc
NB=/home/gburd/ws/osv/.local/alloc
TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-alloc},{Key=Purpose,Value=osv-allocator-microbench}]'
VOLTAG='ResourceType=volume,Tags=[{Key=Owner,Value=agent-alloc}]'
[ -f "$NB/env.boxes" ] && . "$NB/env.boxes"
true
