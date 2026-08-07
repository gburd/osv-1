#!/bin/bash
# remote clone driver on builder
set -e
cd /mnt/nvme
if [ -d osv ]; then
  mv osv "osv.old.$$"
  ( rm -rf "osv.old.$$" & )
fi
: > osv-clone.log
nohup bash -c '
  set -x
  git clone --no-checkout https://github.com/gburd/osv-1.git osv
  cd osv
  git checkout 6b71c76385
  echo CLONE_CHECKOUT_DONE
' > /mnt/nvme/osv-clone.log 2>&1 &
echo "CLONE_PID=$!"
