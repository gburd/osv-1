#!/bin/bash
# ssh helper for leak2 box
IP=3.15.12.26
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i ~/.ssh/osv-lava admin@$IP "$@"
