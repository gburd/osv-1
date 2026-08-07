#!/usr/bin/env bash
# nvmet-tcp multi-target setup for OSv NVMe-oF load test.
# Idempotent: "up" first tears down any existing config so a partial/stale
# state from an interrupted run does not wedge with "Device or resource busy".
#
# Usage (run as root on the target host):
#   sudo ./nvmet-setup.sh up      # create targets (idempotent)
#   sudo ./nvmet-setup.sh down    # tear down + remove backing files
#   sudo ./nvmet-setup.sh status  # show current config
set -uo pipefail

NTARGETS=4
SIZE_GIB=4
BACKING_DIR=/scratch/gburd/nvmeof-b6YEdH/targets
NQN_PREFIX="nqn.2026-06.org.osv:target"
BASE_PORT=4420
TRADDR=0.0.0.0
CFG=/sys/kernel/config/nvmet

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: must run as root (sudo)" >&2
        exit 1
    fi
}

# Remove all port/subsystem config but leave backing files in place.
teardown_config() {
    for i in $(seq 0 $((NTARGETS - 1))); do
        local nqn="${NQN_PREFIX}${i}"
        local p="${CFG}/ports/${i}"
        local sub="${CFG}/subsystems/${nqn}"
        rm -f "${p}/subsystems/${nqn}" 2>/dev/null || true
        [ -d "$p" ] && rmdir "$p" 2>/dev/null || true
        [ -d "${sub}/namespaces/1" ] && rmdir "${sub}/namespaces/1" 2>/dev/null || true
        [ -d "$sub" ] && rmdir "$sub" 2>/dev/null || true
    done
}

up() {
    need_root
    modprobe nvmet
    modprobe nvmet_tcp
    mkdir -p "$BACKING_DIR"

    # Clear any leftover config so addr_* writes never hit a busy port.
    teardown_config

    for i in $(seq 0 $((NTARGETS - 1))); do
        local nqn="${NQN_PREFIX}${i}"
        local backing="${BACKING_DIR}/ns${i}.img"
        local port=$((BASE_PORT + i))

        if [ ! -f "$backing" ]; then
            truncate -s "${SIZE_GIB}G" "$backing"
        fi

        local sub="${CFG}/subsystems/${nqn}"
        mkdir -p "$sub"
        echo 1 > "${sub}/attr_allow_any_host"

        local ns="${sub}/namespaces/1"
        mkdir -p "$ns"
        echo -n "$backing" > "${ns}/device_path"
        echo 1 > "${ns}/enable"

        # Create the port and set its transport address BEFORE linking any
        # subsystem -- nvmet refuses addr_* writes once subsystems are attached.
        local p="${CFG}/ports/${i}"
        mkdir -p "$p"
        echo ipv4 > "${p}/addr_adrfam"
        echo tcp  > "${p}/addr_trtype"
        echo "$TRADDR" > "${p}/addr_traddr"
        echo "$port"   > "${p}/addr_trsvcid"

        ln -sf "$sub" "${p}/subsystems/${nqn}" 2>/dev/null || true

        echo "UP target ${i}: nqn=${nqn} port=${port} backing=${backing} (${SIZE_GIB}GiB)"
    done
    echo "DONE: ${NTARGETS} targets on ${TRADDR}:${BASE_PORT}-$((BASE_PORT + NTARGETS - 1))"
}

down() {
    need_root
    teardown_config
    for i in $(seq 0 $((NTARGETS - 1))); do
        rm -f "${BACKING_DIR}/ns${i}.img"
        echo "DOWN target ${i}"
    done
    echo "DONE: torn down, backing files removed"
}

status() {
    echo "=== subsystems ==="
    ls "${CFG}/subsystems/" 2>/dev/null || echo "(none)"
    echo "=== ports ==="
    for p in "${CFG}"/ports/*/; do
        [ -d "$p" ] || continue
        echo "port $(basename "$p"): $(cat "${p}/addr_traddr"):$(cat "${p}/addr_trsvcid") trtype=$(cat "${p}/addr_trtype")"
        ls "${p}/subsystems/" 2>/dev/null | sed 's/^/    sub: /'
    done
    echo "=== listeners ==="
    ss -tlnp 2>/dev/null | grep -E ":442[0-3]" || echo "(none)"
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    status) status ;;
    *) echo "usage: $0 {up|down|status}" >&2; exit 1 ;;
esac
