#!/bin/bash
# STEP-1 Linux arm: matched ZFS on the SAME raw NVMe (/dev/nvme0n1) the OSv arm used.
# DIRECT on the metal host (as the prior matched run did), NOT a guest.
# Installs zfs-dkms, creates a matched pool, runs syncwrite t8/16/32 with the
# extended bpftrace probe (lwb depth + per-lwb WRITE + block-layer device SERVICE).
# Results -> /work/writedepth-linux/
set -x
exec > /work/linux-arm.log 2>&1
DATADISK=$(cat /work/DATADISK 2>/dev/null || echo /dev/nvme0n1)
OUT=/work/writedepth-linux
mkdir -p "$OUT"

export DEBIAN_FRONTEND=noninteractive
# ZFS + bpftrace + build tools
sudo apt-get install -y linux-headers-$(uname -r) 2>&1 | tail -2
echo "deb http://deb.debian.org/debian bookworm contrib" | sudo tee /etc/apt/sources.list.d/contrib.list
sudo apt-get update -y 2>&1 | tail -2
sudo apt-get install -y zfs-dkms zfsutils-linux bpftrace linux-perf gcc 2>&1 | tail -5
sudo modprobe zfs && echo "ZFS_MODULE_OK" || { echo "FATAL zfs module"; exit 1; }
modinfo zfs | grep -E '^version:' 

# build syncwrite
cat > /work/syncwrite.c <<'CEOF'
/* syncwrite: N threads, each does 8k pwrite + fdatasync in a loop on its own file.
 * Matches the OSv zfs-bench syncwrite isolate. Reports op/s.
 * Usage: syncwrite <dir> <threads> <seconds> */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>

static int g_secs;
static volatile int g_stop = 0;
static char g_dir[512];
#define BS 8192

static unsigned long long now_ns(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec*1000000000ull + ts.tv_nsec;
}

typedef struct { int id; unsigned long long ops; } targ_t;

static void *worker(void *p) {
    targ_t *t = p;
    char path[600];
    snprintf(path, sizeof(path), "%s/sw_%d.dat", g_dir, t->id);
    int fd = open(path, O_CREAT|O_WRONLY|O_TRUNC, 0644);
    if (fd < 0) { perror("open"); return NULL; }
    char *buf = aligned_alloc(4096, BS);
    memset(buf, 0xAB, BS);
    unsigned long long off = 0;
    while (!g_stop) {
        if (pwrite(fd, buf, BS, off) != BS) { perror("pwrite"); break; }
        if (fdatasync(fd) != 0) { perror("fdatasync"); break; }
        t->ops++;
        off += BS;
        if (off > (unsigned long long)512*1024*1024) off = 0; /* recycle within 512MB */
    }
    close(fd); free(buf);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <dir> <threads> <seconds>\n", argv[0]); return 2; }
    strncpy(g_dir, argv[1], sizeof(g_dir)-1);
    int nthreads = atoi(argv[2]);
    g_secs = atoi(argv[3]);
    pthread_t *th = calloc(nthreads, sizeof(pthread_t));
    targ_t *ta = calloc(nthreads, sizeof(targ_t));
    unsigned long long t0 = now_ns();
    for (int i = 0; i < nthreads; i++) { ta[i].id = i; pthread_create(&th[i], NULL, worker, &ta[i]); }
    sleep(g_secs);
    g_stop = 1;
    unsigned long long total = 0;
    for (int i = 0; i < nthreads; i++) { pthread_join(th[i], NULL); total += ta[i].ops; }
    double el = (now_ns() - t0) / 1e9;
    printf("threads=%d secs=%.2f total_ops=%llu op_s=%.0f\n", nthreads, el, total, total/el);
    return 0;
}

CEOF
gcc -O2 -o /work/syncwrite /work/syncwrite.c -lpthread && echo "SYNCWRITE_BUILT"

# make sure no OSv/other pool + wipe labels on the shared device
sudo pkill -9 -f qemu-system 2>/dev/null; sleep 1
sudo zpool destroy zilbench 2>/dev/null || true
sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 conv=fsync 2>/dev/null
sudo dd if=/dev/zero of="$DATADISK" bs=1M count=16 seek=$(( $(sudo blockdev --getsz "$DATADISK")/2048 - 16 )) conv=fsync 2>/dev/null || true

# matched pool geometry (same as OSv zfs-bench: ashift=12, 8k recsize, comp=off, sync=standard)
sudo zpool create -f -o ashift=12 zilbench "$DATADISK"
sudo zfs set recordsize=8k compression=off atime=off sync=standard logbias=latency zilbench
sudo mkdir -p /zilbench/sw && sudo chmod 777 /zilbench/sw
zpool status zilbench; zfs get recordsize,compression,sync,logbias zilbench

DIR=/zilbench/sw
for THR in 8 16 32; do
  echo "======== LINUX t=$THR ========"
  sudo rm -f $DIR/*.dat
  sudo bpftrace /work/lwb_probe_linux.bt > $OUT/probe_t${THR}.out 2>$OUT/probe_t${THR}.err &
  BP=$!
  sleep 3
  # 3 reps x 30s to match OSv reps
  for r in 1 2 3; do
    /work/syncwrite $DIR $THR 30 | tee -a $OUT/work_t${THR}.out
  done
  sleep 1
  sudo kill -INT $BP 2>/dev/null || true
  wait $BP 2>/dev/null || true
  echo "---- probe summary t=$THR ----"
  grep -E "max_inflight|mean_inflight|flush_count" $OUT/probe_t${THR}.out || true
done

sudo zpool export zilbench 2>/dev/null || true
echo "LINUX_ARM_DONE"
