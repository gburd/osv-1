#!/bin/bash
set -u
LOG=/tmp/p-instrA-t32.log
sudo docker exec -d bld bash /work/run-point.sh $LOG 32 30 3 "--env=OSV_BLK_MQ_COMPLETE=1" ""
sleep 12
iostat -x 1 40 /dev/nvme1n1 > /home/ec2-user/instrA-iostat-t32.txt 2>&1 &
IOP=$!
for i in $(seq 1 12); do
  echo "=== toph t=$i $(date +%s) ===" >> /home/ec2-user/instrA-toph-t32.txt
  top -H -b -n1 -o %CPU | grep -iE 'qemu|%Cpu|PID' | head -50 >> /home/ec2-user/instrA-toph-t32.txt
  sleep 3
done
wait $IOP 2>/dev/null
echo INSTRA_DONE
