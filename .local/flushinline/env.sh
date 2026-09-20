export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR"
METALID=i-00bce9be7b8f34a9f
DRVID=i-0dcf2ad4d13a65dd4
METAL=admin@18.226.34.56
DRV=admin@18.189.186.69
METALPRIV=172.31.3.108
DRVPRIV=172.31.7.169
