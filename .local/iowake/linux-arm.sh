#!/bin/bash
# Linux ZFS arm: create the pool on the SAME NVMe with the SAME geometry as the
# OSv arm, build a host binary of zfs-bench.c that skips the OSv-only pool
# bring-up (host zpool did it) and runs the workload against the mountpoint.
set -x
exec > /home/ec2-user/linux-arm.log 2>&1
echo "=== START $(date) ==="
export PATH=/usr/local/sbin:/usr/local/bin:$PATH
ZPOOL=/usr/local/sbin/zpool
ZFS=/usr/local/sbin/zfs
NVME=/dev/nvme1n1
POOL=bench
DS=$POOL/fs

# Tear down any prior pool on this device, wipe labels.
sudo $ZPOOL destroy -f $POOL 2>/dev/null
sudo wipefs -a $NVME 2>/dev/null
sudo $ZPOOL labelclear -f $NVME 2>/dev/null

# MATCHED geometry: ashift=12 recordsize=8k compression=off atime=off
# sync=standard logbias=latency primarycache=all (last three are defaults but set explicit).
sudo $ZPOOL create -f -o ashift=12 \
    -O compression=off -O atime=off -O sync=standard -O logbias=latency \
    -O primarycache=all -O mountpoint=/$POOL $POOL $NVME 2>&1
echo "ZPOOL_CREATE_RC=$?"
sudo $ZFS create -o recordsize=8k -o mountpoint=/$POOL/fs $DS 2>&1
echo "ZFS_CREATE_RC=$?"
sudo $ZPOOL get ashift $POOL 2>&1
sudo $ZFS get recordsize,compression,atime,sync,logbias,primarycache $DS 2>&1
# make the dataset writable by ec2-user
sudo chown -R ec2-user:ec2-user /$POOL/fs 2>&1
df -h /$POOL/fs 2>&1

# Build the host binary. Add HOST_BUILD guards to skip OSv-only externs + pool
# bring-up; pass ds=bench/fs so paths resolve to /bench/fs/<file> (the mount).
cd /home/ec2-user/osv
cp scripts/bench/zfs-bench.c /home/ec2-user/zfs-bench-host.c
python3 - <<'PY'
import re
p='/home/ec2-user/zfs-bench-host.c'
s=open(p).read()
# 1. stub the two OSv externs under HOST_BUILD
s=s.replace(
'extern int osv_run_app(const char *app_path, const char *args[], int args_len);\nextern void zfsdev_init(void);',
'#ifdef HOST_BUILD\nstatic int osv_run_app(const char *a,const char *b[],int c){(void)a;(void)b;(void)c;return 0;}\nstatic void zfsdev_init(void){}\n#else\nextern int osv_run_app(const char *app_path, const char *args[], int args_len);\nextern void zfsdev_init(void);\n#endif')
# 2. under HOST_BUILD skip create_pool + make_ds; use ds= directly (host made the pool)
s=s.replace(
'    if (create_pool(&o) != 0) { printf("RESULT FAIL zpool create\\n"); return 1; }\n    char ds[128]; make_ds(&o, ds, sizeof ds);',
'    char ds[128];\n#ifdef HOST_BUILD\n    /* host created the pool+dataset; ds= must be the mountpoint-relative path */\n    set_str(ds, sizeof ds, o.ds[0] ? o.ds : "bench/fs");\n#else\n    if (create_pool(&o) != 0) { printf("RESULT FAIL zpool create\\n"); return 1; }\n    make_ds(&o, ds, sizeof ds);\n#endif')
# 3. guard the two post-create status run_cmd blocks + direct set (call /zpool.so - noop on host but harmless; still guard to avoid confusing output)
s=s.replace(
'    { const char *a[] = {"zpool", "status", o.pool}; run_cmd("/zpool.so", a, 3); }',
'#ifndef HOST_BUILD\n    { const char *a[] = {"zpool", "status", o.pool}; run_cmd("/zpool.so", a, 3); }\n#endif')
open(p,'w').write(s)
print("patched")
PY
grep -c HOST_BUILD /home/ec2-user/zfs-bench-host.c

gcc -O2 -std=gnu11 -D_GNU_SOURCE -DHOST_BUILD -o /home/ec2-user/zfs-bench-host \
    /home/ec2-user/zfs-bench-host.c -lm 2>&1
echo "GCC_RC=$?"
ls -l /home/ec2-user/zfs-bench-host 2>&1
echo "=== END $(date) ==="
echo LINUX_ARM_SETUP_DONE
