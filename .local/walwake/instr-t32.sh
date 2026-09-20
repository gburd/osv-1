#!/bin/bash
# Launch a threads=32 fsync run detached, and capture host NVMe %util (iostat)
# + per-vCPU busy (mpstat/top) DURING the run. Writes to /tmp files on the box.
set -u
LOG=/tmp/p-instr-t32.log
cd /work/osv 2>/dev/null || true
# start the guest run detached inside the container
sudo docker exec -d bld bash /work/run-point.sh $LOG 32 30 3 "" ""
# give it a few s to boot + create pool, then sample host during the timed part
sleep 12
# iostat on the NVMe (1s x 40)
iostat -x 1 40 /dev/nvme1n1 > /home/ec2-user/instr-iostat-t32.txt 2>&1 &
IOP=$!
# per-vCPU busy: mpstat all cpus (1s x 40) - shows how many of 96 host vCPU are busy
mpstat -P ALL 1 40 > /home/ec2-user/instr-mpstat-t32.txt 2>&1 &
MP=$!
# qemu per-thread (vCPU) busy via top -H, a few snapshots
for i in $(seq 1 12); do
  echo "=== toph t=$i $(date +%s) ===" >> /home/ec2-user/instr-toph-t32.txt
  top -H -b -n1 -o %CPU | grep -iE 'qemu|%Cpu|PID' | head -45 >> /home/ec2-user/instr-toph-t32.txt
  sleep 3
done
wait $IOP $MP 2>/dev/null
echo INSTR_DONE
