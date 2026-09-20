export AWS_PROFILE=lava AWS_DEFAULT_REGION=us-east-2
K=/home/gburd/.ssh/osv-lava
SSHO="-i $K -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o LogLevel=ERROR"
# Filled in as boxes launch:
METALID="i-0179b5abdcea6333b"
DRVID="i-0929075f9348808d7"
METAL="admin@18.218.36.169"
DRV="admin@18.216.187.52"
METALPRIV="172.31.22.151"
