#!/bin/bash
# ssh helper for leak2real box i-0a13d716cee541d70
IP=3.148.227.10
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i ~/.ssh/osv-lava admin@$IP "$@"
