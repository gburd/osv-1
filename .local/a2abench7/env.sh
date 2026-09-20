export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
KEY=osv-lava
SG=sg-0a954e440478e063d
SUBNET=subnet-0230d1c45d8a098a7
AMI_X86=ami-0eff088391f589f50
AMI_ARM=ami-01c02d0105285e20d
AMI_UBU=ami-00adec9774170bad2
OWNER=agent-a2abench7
# filled in by launch
[ -f /home/gburd/ws/osv/.local/a2abench7/env.boxes ] && . /home/gburd/ws/osv/.local/a2abench7/env.boxes
X86=ec2-user@3.129.70.203
ARM=ec2-user@18.217.207.217
DRVX=ubuntu@3.148.179.148
DRVA=ubuntu@3.144.115.73
X86PRIV=172.31.1.7
ARMPRIV=172.31.5.123
X86ID=i-0ce983c4cb91921cf
ARMID=i-031434d1538558de9
DRVXID=i-06b5f679718f7e389
DRVAID=i-02162e8211e14b30f
