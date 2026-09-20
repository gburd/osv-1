export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR"
METALID="i-0d2d3a537feb2c14d"
DRVID="i-0d72ade3bc1516018"   # Ubuntu 24.04 (HammerDB needs glibc 2.38+)
METAL="admin@3.141.26.215"
DRV="ubuntu@13.59.218.178"
METALPRIV="172.31.22.199"
DRVPRIV="172.31.20.88"
