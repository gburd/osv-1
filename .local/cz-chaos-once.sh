#!/usr/bin/env bash
# Bounded Crucible chaos test: run the ZFS-on-Crucible workload against three
# downstairs on three hosts, kill ONE downstairs (arnold) mid-workload, confirm
# the pool survives on 2/3 quorum and the sweep still completes, then restart
# the killed downstairs and confirm it reconnects/live-repairs.
#
# Run locally; orchestrates meh (guest + local downstairs) and arnold (victim)
# over ssh. nuc stays up the whole time as the second healthy replica.
set -uo pipefail

SSH="ssh -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=10 -i $HOME/.ssh/id_ed25519"
UUID=a878bbd3-17ef-40fe-bfc5-7a21ebe9d7de
ARNOLD_BIN=/home/gburd/crucible-build/target/release/crucible-downstairs
ARNOLD_DATA=/home/gburd/crucible-data/mh-r1
RUNLOG=/scratch/gburd/cz-chaos-run.log

echo "[chaos] launching guest workload on meh (background) ..."
# run.py in background on meh, logging to RUNLOG. 300s timeout caps the run.
$SSH meh "bash -c 'cd /scratch/gburd/osv-build; nohup timeout 300 nix-shell -p boost ncurses --run \"./scripts/run.py -k --arch=x86_64 --vnc none -m 1024 -c2 --novnc --crucible0=192.168.122.1:3821,100.76.219.47:3821,100.117.233.104:3821 --crucible0-uuid=$UUID --crucible-block-size=4096 -e tests/tst-crucible-zfs.so\" > $RUNLOG 2>&1 &' "
echo "[chaos] waiting 55s for guest to boot + enter workload sweep ..."
sleep 55

echo "[chaos] --- guest progress so far ---"
$SSH meh "grep -E 'PASS|size|MiB|suspended' $RUNLOG | tail -8"

echo "[chaos] KILLING arnold downstairs (simulating host failure) ..."
$SSH arnold "pkill -f 'crucible-downstairs run.*mh-r1'; echo arnold downstairs killed"
KILL_T=$(date +%s)

echo "[chaos] letting workload continue on 2/3 (meh+nuc) for 40s ..."
sleep 40
echo "[chaos] --- progress AFTER kill (should still advance) ---"
$SSH meh "grep -E 'PASS|MiB|suspended|quorum' $RUNLOG | tail -10"

echo "[chaos] RESTARTING arnold downstairs (live-repair) ..."
$SSH arnold "nohup $ARNOLD_BIN run --address 0.0.0.0 --port 3821 --data $ARNOLD_DATA > $ARNOLD_DATA/../ds-3821.log 2>&1 & sleep 2; pgrep -af 'crucible-downstairs run.*mh-r1' | head"

echo "[chaos] waiting for guest run to finish ..."
for i in $(seq 1 40); do
  if $SSH meh "grep -q 'RUN_DONE\|workload sweep\|terminating on signal' $RUNLOG 2>/dev/null"; then break; fi
  sleep 5
done

echo "[chaos] ================= FINAL GUEST LOG ================="
$SSH meh "tail -40 $RUNLOG"
echo "[chaos] ================= END ================="
