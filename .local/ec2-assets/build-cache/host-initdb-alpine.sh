#!/bin/bash
# host-initdb-alpine.sh -- run the OSv-built (musl-PIE) initdb NATIVELY under
# Alpine's musl loader to produce a seed cluster, since OSv stubs popen() (which
# initdb needs). Output: $SEED, ready to cpiod-stream into the OSv ZFS pool.
# Run on the HOST (needs docker). PG install tree at /mnt/nvme/osv/.local/pg18/install.
set -eu
SEED=${SEED:-/mnt/nvme/pgseed}
INSTALL=${INSTALL:-/mnt/nvme/osv/.local/pg18/install}
sudo mkdir -p "$SEED"; sudo find "$SEED" -mindepth 1 -delete 2>/dev/null || true
sudo docker run --rm -v "$INSTALL":"$INSTALL" -v "$(dirname "$SEED")":"$(dirname "$SEED")" alpine:latest sh -c "
adduser -D -u 70 pg 2>/dev/null; chown -R pg '$SEED'
export LD_LIBRARY_PATH='$INSTALL/lib'
su pg -s /bin/sh -c \"HOME=/tmp '$INSTALL/bin/initdb' -D '$SEED' -U postgres --locale-provider=builtin --builtin-locale=C -E UTF8\"
echo 'host all all 0.0.0.0/0 trust' >> '$SEED/pg_hba.conf'
echo 'local all all trust' >> '$SEED/pg_hba.conf'"
echo "seed cluster ready at $SEED"
