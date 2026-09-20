export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-lava
SG=sg-0a954e440478e063d
SUBNET=subnet-0230d1c45d8a098a7
AMI_X86=ami-0eff088391f589f50
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-a2a3lever
[ -f /home/gburd/ws/osv/.local/a2a3lever/env.boxes ] && . /home/gburd/ws/osv/.local/a2a3lever/env.boxes
