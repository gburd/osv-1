#!/usr/bin/env bash
#
# Multi-host Crucible downstairs orchestrator for the OSv ZFS-on-Crucible
# chaos test.  Unlike the single-host scripts in .local/scratch/, this drives
# three downstairs replicas of ONE volume spread across three machines:
#
#   nuc    100.76.219.47:3801   FreeBSD 15.0  (cargo build)
#   meh    100.98.177.68:3801   Linux/NixOS   (nix build)
#   arnold 100.117.233.104:3801 Fedora 44     (cargo build)
#
# The OSv upstairs (QEMU guest on floki) connects to all three over tailscale
# and requires 2/3 quorum, so this topology survives any single host dying.
#
# Region geometry matches .local/cluster/r1/region.json:
#   block_size 4096, extent_size 16384 blocks, extent_count 64  => 4 GiB.
# (Per-downstairs region UUIDs may differ; the OSv upstairs validates only
#  geometry, not UUID.)
#
# Subcommands:
#   start    create regions (idempotent) and launch a downstairs on each host
#   stop     kill the downstairs on each host
#   status   show liveness + listening port on each host
#   targets  print the --crucible=... string for scripts/run.py
#   chaos N  run N rounds of kill-one / wait / restart fault injection
#
set -euo pipefail

# host alias : tailnet-ip : binary-path : extra-env
NUC_BIN='$HOME/crucible-build/target/release/crucible-downstairs'
ARNOLD_BIN='$HOME/crucible-build/target/release/crucible-downstairs'
MEH_BIN='$HOME/crucible-build/result-downstairs/bin/crucible-downstairs'

NUC_IP=100.76.219.47
MEH_IP=100.98.177.68
ARNOLD_IP=100.117.233.104

PORT=3801
DATA='$HOME/crucible-data/r1'
LOG='$HOME/crucible-data/ds.log'

HOSTS=(nuc meh arnold)
declare -A HOST_IP=( [nuc]=$NUC_IP [meh]=$MEH_IP [arnold]=$ARNOLD_IP )
declare -A HOST_BIN=( [nuc]=$NUC_BIN [meh]=$MEH_BIN [arnold]=$ARNOLD_BIN )
# arnold needs the runtime sqlite lib on LD_LIBRARY_PATH (built against a
# user-local symlink); harmless on the others.
declare -A HOST_ENV=( [nuc]='' [meh]='' [arnold]='LD_LIBRARY_PATH=/usr/lib64' )

# Remote shells differ (fish on meh, sh on nuc/arnold); always wrap in bash -c.
# Use -c not -lc to avoid FreeBSD's login MOTD banner polluting status output.
rsh() { local h=$1; shift; ssh "$h" "bash -c $(printf '%q' "$*")"; }

cmd_start() {
    for h in "${HOSTS[@]}"; do
        local bin=${HOST_BIN[$h]} env=${HOST_ENV[$h]}
        echo "==> $h: ensure region + launch downstairs on ${HOST_IP[$h]}:$PORT"
        rsh "$h" "mkdir -p \$(dirname $DATA);
                  if [ ! -f $DATA/region.json ]; then
                      $env $bin create --uuid \$(uuidgen) --extent-count 64 \
                          --extent-size 16384 --block-size 4096 --data $DATA;
                  fi;
                  if pgrep -f 'crucible-downstairs run' >/dev/null 2>&1; then
                      echo 'already running';
                  else
                      nohup $env $bin run --address 0.0.0.0 --port $PORT \
                          --data $DATA > $LOG 2>&1 &
                      echo \"started pid \$!\";
                  fi"
    done
    echo; cmd_status
}

cmd_stop() {
    for h in "${HOSTS[@]}"; do
        echo "==> $h: stop downstairs"
        rsh "$h" "pkill -f 'crucible-downstairs run' && echo stopped || echo 'not running'"
    done
}

cmd_status() {
    for h in "${HOSTS[@]}"; do
        printf '%-7s %s:%s  ' "$h" "${HOST_IP[$h]}" "$PORT"
        if rsh "$h" "pgrep -f 'crucible-downstairs run' >/dev/null 2>&1"; then
            printf 'UP'
        else
            printf 'DOWN'
        fi
        # TCP reach from this host (floki)
        if timeout 4 bash -c "echo > /dev/tcp/${HOST_IP[$h]}/$PORT" 2>/dev/null; then
            printf '  (reachable)\n'
        else
            printf '  (UNREACHABLE)\n'
        fi
    done
}

cmd_targets() {
    echo "--crucible=$NUC_IP:$PORT,$MEH_IP:$PORT,$ARNOLD_IP:$PORT --crucible-uuid=2321c7c3-8084-41f3-a6de-fa368d51e3b6 --crucible-block-size=4096"
}

cmd_chaos() {
    local rounds=${1:-5}
    echo "==> chaos: $rounds rounds (kill one downstairs, wait, restart)"
    for ((i=1; i<=rounds; i++)); do
        local victim=${HOSTS[$((RANDOM % ${#HOSTS[@]}))]}
        echo "--- round $i/$rounds: victim=$victim"
        rsh "$victim" "pkill -f 'crucible-downstairs run' && echo killed || echo 'already down'"
        sleep $((10 + RANDOM % 20))
        local bin=${HOST_BIN[$victim]} env=${HOST_ENV[$victim]}
        rsh "$victim" "nohup $env $bin run --address 0.0.0.0 --port $PORT \
                       --data $DATA > $LOG 2>&1 & echo \"restarted pid \$!\""
        sleep $((10 + RANDOM % 20))
        cmd_status
    done
}

case "${1:-status}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    targets) cmd_targets ;;
    chaos)   cmd_chaos "${2:-5}" ;;
    *) echo "usage: $0 {start|stop|status|targets|chaos N}" >&2; exit 1 ;;
esac
