#!/bin/bash
# Fresh-boot one arm and wait until it SERVES.
#
# FRESH BOOT = full STOP/START, not reboot.  Measured, not assumed:
#   OSv native REBOOT is BROKEN on this substrate (boot16 real-mode disk-read
#   failure loop, "Error reading disk (real mode): 0x67" every retry -- the
#   device is stuck, not transiently busy).  A full stop/start boots cleanly.
#   Stop/start is also strictly BETTER for the methodology: the instance store is
#   discarded on stop, so every cell provably begins on a pristine NVMe with a
#   freshly created pool on BOTH arms, and neither arm carries state across cells.
# ARGS: <arm: osv|lin>
set -u
ARM=$1
. /home/gburd/ws/osv/.local/bench24/env.sh

if [ "$ARM" = osv ]; then H=$OSVPRIV; ID=$OSVID; else H=$LINUXPRIV; ID=$LINUXID; fi

aws ec2 stop-instances  --region $REGION --instance-ids $ID >/dev/null
aws ec2 wait instance-stopped --region $REGION --instance-ids $ID
aws ec2 start-instances --region $REGION --instance-ids $ID >/dev/null
aws ec2 wait instance-running --region $REGION --instance-ids $ID

# Re-read the private IP rather than trusting stability across stop/start.
NEWIP=$(aws ec2 describe-instances --region $REGION --instance-ids $ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
if [ "$NEWIP" != "$H" ]; then
  echo "NOTE: $ARM private IP changed $H -> $NEWIP, updating env.boxes"
  if [ "$ARM" = osv ]; then sed -i "s/^OSVPRIV=.*/OSVPRIV=$NEWIP/" "$NB/env.boxes"
  else sed -i "s/^LINUXPRIV=.*/LINUXPRIV=$NEWIP/" "$NB/env.boxes"; fi
  H=$NEWIP
fi
sleep 10

if [ "$ARM" = lin ]; then
  # The PUBLIC IP does change across stop/start (no EIP), so re-resolve it.
  NEWPUB=$(aws ec2 describe-instances --region $REGION --instance-ids $ID \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  sed -i "s|^LINUX=.*|LINUX=ubuntu@$NEWPUB|" "$NB/env.boxes"
  LINUX=ubuntu@$NEWPUB
  for i in $(seq 1 40); do
    ssh $SSHO -o ConnectTimeout=8 $LINUX "true" 2>/dev/null && break
    sleep 10
  done
  scp $SSHO "$NB/linux-pg.sh" $LINUX:/tmp/ >/dev/null 2>&1
  ssh $SSHO $LINUX "bash /tmp/linux-pg.sh fresh >/dev/null 2>&1; grep -E 'io_method|io_workers|LINUXPG_DONE' /tmp/linux-pg-fresh.log | tail -3"
fi

for i in $(seq 1 60); do
  if ssh $SSHO $DRV "timeout 4 bash -c '</dev/tcp/$H/5432'" 2>/dev/null; then
    echo "BOOT_OK $ARM serving after $((10+i*10))s host=$H"
    exit 0
  fi
  sleep 10
done
echo "BOOT_FAIL $ARM did not serve"
exit 1
