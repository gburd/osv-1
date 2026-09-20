export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
KEY=osv-lava
SG=sg-0a954e440478e063d
SUBNET=subnet-0230d1c45d8a098a7
AMI_X86=ami-0eff088391f589f50
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-zilab
BRANCH=bench/zil-hires-ab-v2

X86ID=i-035bbc5224b0eecbf
DRVID=i-01869557eb2764838
X86=ec2-user@13.59.94.13
DRV=ubuntu@3.138.116.180
X86PRIV=172.31.5.80
DRVPRIV=172.31.8.64
GUEST=$X86PRIV   # driver reaches guest via metal private IP:5432 (DNAT)
