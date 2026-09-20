#!/bin/bash
# ssh helper for leak2b box i-0d75e6472ec9328ea
IP=18.118.28.4
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i ~/.ssh/osv-lava admin@$IP "$@"
