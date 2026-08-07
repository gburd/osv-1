#!/usr/bin/env bash
#
# Start a 9-volume × 3-replica Crucible downstairs cluster on `meh` using podman.
#
# Layout:
#   r2-d0 .. r2-d3  (RAID-Z2 data, 4 volumes)
#   r2-p0 .. r2-p1  (RAID-Z2 parity, 2 volumes)
#   slog-a, slog-b  (mirrored ZIL log)
#   l2arc           (read cache)
#
# Each volume = 3 downstairs replicas; each replica = one podman container
# bound to host port 4XYZ where X is the volume index, YZ is replica 1..3.
# Region size: 1 GiB (4 KiB block × 1024 blocks/extent × 256 extents).
#
# Run as the user that built the binaries.  Run on `meh`.
#
set -euo pipefail

CRUCIBLE_DIR="${CRUCIBLE_DIR:-/scratch/crucible-test/crucible}"
DATA_DIR="${DATA_DIR:-/scratch/crucible-data}"
DS_BIN="$CRUCIBLE_DIR/target/release/crucible-downstairs"

if ! [[ -x "$DS_BIN" ]]; then
    echo "ERROR: $DS_BIN not found or not executable" >&2
    exit 1
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found in PATH" >&2
    exit 1
fi

VOLUMES=(r2-d0 r2-d1 r2-d2 r2-d3 r2-p0 r2-p1 slog-a slog-b l2arc)

mkdir -p "$DATA_DIR"
UUID_FILE="$DATA_DIR/volume-uuids"

# Generate or load per-volume UUIDs.  All 3 replicas of the same volume MUST
# use the same UUID (the Crucible upstairs verifies this).
if [[ ! -f "$UUID_FILE" ]]; then
    : > "$UUID_FILE"
    for vol in "${VOLUMES[@]}"; do
        printf '%s %s\n' "$vol" "$(uuidgen)" >> "$UUID_FILE"
    done
fi
declare -A VOL_UUID
while read -r vol uuid; do
    VOL_UUID["$vol"]="$uuid"
done < "$UUID_FILE"

echo "==> Phase 1: create regions (host-side, fast)"
for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    uuid="${VOL_UUID[$vol]}"
    for r in 0 1 2; do
        region_dir="$DATA_DIR/${vol}-r${r}"
        if [[ -d "$region_dir/00" ]]; then
            echo "  ${vol}-r${r}: region exists, skipping"
            continue
        fi
        mkdir -p "$region_dir"
        echo "  ${vol}-r${r}: creating region (uuid $uuid)"
        "$DS_BIN" create \
            --uuid "$uuid" \
            --extent-count 256 \
            --extent-size 1024 \
            --block-size 4096 \
            --data "$region_dir" \
            >/dev/null
    done
done

echo
echo "==> Phase 2: stop any old downstairs containers"
podman ps -a --filter "label=crucible-test" --format "{{.Names}}" \
    | xargs -r podman rm -f >/dev/null 2>&1 || true

echo
echo "==> Phase 3: launch 27 downstairs containers"
# Bind-mount /nix/store (RO) and the binary; use --network host so OSv
# (running on a different machine) can reach the port directly via meh's
# IP.  SSL_CERT_FILE points reqwest at the host's CA bundle (busybox has
# no /etc/ssl/certs); the bundle lives in /nix/store and is already
# mounted.
#
# Sequential start: rootless podman serialises container DB writes in a
# single sqlite file, and >2 concurrent `podman run -d` calls cause
# "database is locked" errors that leave only a handful of containers
# alive after 10+ minutes.  Sequential start is slower (~1.5 s per
# container) but reliable.
ca_bundle=$(readlink -f /etc/ssl/certs/ca-bundle.crt)

for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    port_base=$((4000 + i * 10 + 1))
    for r in 0 1 2; do
        port=$((port_base + r))
        region_dir="$DATA_DIR/${vol}-r${r}"
        name="ds-${vol}-r${r}"
        podman run -d \
            --name "$name" \
            --label crucible-test=1 \
            --network host \
            -v /nix/store:/nix/store:ro \
            -v "$DS_BIN":/usr/local/bin/crucible-downstairs:ro \
            -v "$region_dir":/data \
            -e SSL_CERT_FILE="$ca_bundle" \
            docker.io/library/busybox:latest \
            /usr/local/bin/crucible-downstairs run \
                --address 0.0.0.0 \
                --port "$port" \
                --data /data \
            >/dev/null
        printf '.'
    done
done
echo
echo "  launched 27 containers"

echo
echo "==> Phase 4: verify all 27 containers are running"
sleep 2
running=$(podman ps --filter "label=crucible-test" --format "{{.Names}}" | wc -l)
if [[ "$running" -ne 27 ]]; then
    echo "ERROR: expected 27 running containers, got $running" >&2
    podman ps --filter "label=crucible-test" --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi
echo "All 27 containers running"

echo
echo "==> Phase 5: print target strings for OSv run.py"
echo
HOST_IP="${HOST_IP:-$(ip -4 -o addr show enp12s0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)}"
HOST_IP="${HOST_IP:-127.0.0.1}"
for i in "${!VOLUMES[@]}"; do
    vol="${VOLUMES[$i]}"
    uuid="${VOL_UUID[$vol]}"
    port_base=$((4000 + i * 10 + 1))
    targets="$HOST_IP:$port_base,$HOST_IP:$((port_base+1)),$HOST_IP:$((port_base+2))"
    if [[ "$i" -eq 0 ]]; then
        printf '  --crucible=%s --crucible-uuid=%s\n' "$targets" "$uuid"
    else
        printf '  --crucible%d=%s --crucible%d-uuid=%s\n' \
            "$((i-1))" "$targets" "$((i-1))" "$uuid"
    fi
done

echo
echo "==> To shut down: podman ps --filter label=crucible-test -q | xargs podman rm -f"
