export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-lava
SG=sg-0a954e440478e063d
SUBNET=subnet-0230d1c45d8a098a7
AMI_DEB=ami-0dc1629a58a7d6458
OWNER=agent-lwbpipe
[ -f /home/gburd/ws/osv/.local/lwbpipe/env.boxes ] && . /home/gburd/ws/osv/.local/lwbpipe/env.boxes
