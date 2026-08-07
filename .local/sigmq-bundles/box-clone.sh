#!/bin/bash
set -e
echo "=== connectivity to github ==="
timeout 15 curl -sI https://github.com 2>&1 | head -1 || echo "no github?"
which git rsync >/dev/null 2>&1 || sudo dnf install -y -q git rsync >/dev/null 2>&1
cd /mnt/nvme
[ -d osv ] && rm -rf osv
git clone -q /mnt/nvme/sigmq.bundle osv 2>&1 | tail -3
cd osv
git remote set-url origin https://github.com/gburd/osv-1.git 2>/dev/null || git remote add origin https://github.com/gburd/osv-1.git
git branch unfixed 861be4908 2>&1 || echo "unfixed at $(git rev-parse --short 861be4908)"
git checkout -q 861be4908 2>&1 | tail -2 || true
echo "HEAD: $(git log --oneline -1)"
git branch -a
echo "CLONE_DONE"
