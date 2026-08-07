#!/usr/bin/env bash
#
# Start a Crucible downstairs cluster of 9 volumes (27 downstairs replicas)
# for the OSv ZFS RAID-Z2 + SLOG + L2ARC test.
#
# Each volume is identified by name; ports are assigned as 4XY1, 4XY2, 4XY3
# where XY is the zero-indexed volume number.  Region size: 1 GiB per
# downstairs (4 KiB block × 1024 blocks/extent × 256 extents).
#
# Run as the user that built the binaries (NOT root) so the data directory
# permissions match.  Uses native binaries, no podman.  We considered using
# podman but the downstairs binary already binds host network ports and
# touches large files; the only benefit of containerisation here would be
# isolation, which we don't need on a single-purpose test host.
#
# Usage:
#   start-downstairs.sh <crucible-source-dir> <data-dir> <bind-addr>
# Example:
#   start-downstairs.sh /scratch/crucible-test/crucible /scratch/crucible-data 0.0.0.0
#
set -euo pipefail

CRUCIBLE_DIR="${1:-/scratch/crucible-test/crucible}"
DATA_DIR="${2:-/scratch/crucible-data}"
BIND_ADDR="${3:-0.0.0.0}"

DS_BIN="$CRUCIBLE_DIR/target/release/crucible-downstairs"
DSC_BIN="$CRUCIBLE_DIR/target/release/dsc"

if ! [[ -x "$DS_BIN" && -x "$DSC_BIN" ]]; then
    echo "ERROR: Crucible binaries not found at $DS_BIN" >&2
    echo "Build first: cd $CRUCIBLE_DIR && nix develop --command cargo build --release --workspace --bins" >&2
    exit 1
fi

# Volume names match the OSv test layout.
VOLUMES=(r2-d0 r2-d1 r2-d2 r2-d3 r2-p0 r2-p1 slog-a slog-b l2arc)

# 9 volumes × 3 replicas, ports 4001..4083
mkdir -p "$DATA_DIR"

echo "==> Creating regions for ${#VOLUMES[@]} volumes (${#VOLUMES[@]} × 3 replicas)"
for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    port_base=$((4000 + i * 10 + 1))
    for r in 0 1 2; do
        port=$((port_base + r))
        region_dir="$DATA_DIR/${vol}-r${r}"
        if [[ -d "$region_dir/00" ]]; then
            echo "  ${vol}-r${r}: region exists at $region_dir, skipping create"
            continue
        fi
        echo "  ${vol}-r${r}: creating region at $region_dir (port $port)"
        "$DS_BIN" create \
            --uuid "$(uuidgen)" \
            --extent-count 256 \
            --extent-size 1024 \
            --block-size 4096 \
            --data "$region_dir"
    done
done

echo
echo "==> Starting downstairs processes"
PIDS=()
LOGDIR="$DATA_DIR/logs"
mkdir -p "$LOGDIR"

for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    port_base=$((4000 + i * 10 + 1))
    for r in 0 1 2; do
        port=$((port_base + r))
        region_dir="$DATA_DIR/${vol}-r${r}"
        log="$LOGDIR/${vol}-r${r}.log"
        "$DS_BIN" run \
            --address "$BIND_ADDR" \
            --port "$port" \
            --data "$region_dir" \
            >"$log" 2>&1 &
        PIDS+=($!)
        echo "  ${vol}-r${r}: PID $! on $BIND_ADDR:$port (log: $log)"
    done
done

echo
echo "==> All ${#PIDS[@]} downstairs started"
echo "PIDs: ${PIDS[*]}"
echo "$$" > "$DATA_DIR/orchestrator.pid"
printf '%s\n' "${PIDS[@]}" > "$DATA_DIR/downstairs.pids"

# Print the per-volume target strings the OSv side will need.
echo
echo "==> Target strings for OSv run.py:"
for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    port_base=$((4000 + i * 10 + 1))
    targets="$BIND_ADDR:$((port_base)),$BIND_ADDR:$((port_base+1)),$BIND_ADDR:$((port_base+2))"
    printf '  --crucible%d=%s\n' "$i" "$targets"
done

echo
echo "==> Waiting for SIGTERM/SIGINT to clean up"
trap 'echo "Stopping downstairs..."; kill "${PIDS[@]}" 2>/dev/null; wait; exit 0' INT TERM
wait
