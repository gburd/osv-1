export AWS_PROFILE=hotdog AWS_DEFAULT_REGION=us-east-2
REGION=us-east-2
K=/home/gburd/.ssh/osv-hotdog
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-hotdog
SG=sg-0a0fec26afe57cd43
SUBNET=subnet-04a66ccb68b2a2f13
AMI_AL=ami-0f18589f7b30835ef
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-projmax
PM=/home/gburd/ws/osv/.local/projmax
NB=/home/gburd/ws/osv/.local/native
TAGSPEC='ResourceType=instance,Tags=[{Key=Owner,Value=agent-projmax},{Key=Purpose,Value=projected-max-native-pg}]'
[ -f "$PM/env.boxes" ] && . "$PM/env.boxes"
true
