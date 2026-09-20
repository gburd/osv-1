export AWS_PROFILE=bene AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-bene
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o LogLevel=ERROR"
X86=ec2-user@18.224.44.60
ARM=ec2-user@13.59.103.7
DRVX=ubuntu@3.143.7.47
DRVA=ubuntu@52.15.179.79
X86ID=i-0126a936629a68911
ARMID=i-09744de8dee537964
DRVXID=i-01a9667ad35f58299
DRVAID=i-09dfc1589c8eb9c2c
