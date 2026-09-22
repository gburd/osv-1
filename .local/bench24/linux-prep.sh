#!/bin/bash
# LINUX-NATIVE arm setup (and the driver's pgbench 18 client).
# Ubuntu 24.04 running DIRECTLY on the instance -- it IS the host OS, not a guest.
# ZFS pool on the SAME raw local NVMe device, PG18 from PGDG.
# Each apt step is INDEPENDENT: one missing package must not abort the rest
# (a linux-modules-extra glob miss silently aborted the whole install once).
set -x
exec > /tmp/linux-prep.log 2>&1
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl ca-certificates gnupg sysstat numactl jq bc 2>&1 | tail -3
sudo apt-get install -y -qq zfsutils-linux 2>&1 | tail -3
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) 2>&1 | tail -2 || echo "NOTE: modules-extra not needed on this kernel"
sudo apt-get install -y -qq postgresql-common 2>&1 | tail -3

# PGDG repo, added directly (the postgresql-common helper script is not always shipped).
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -qq
sudo apt-get install -y -qq postgresql-18 postgresql-client-18 2>&1 | tail -5

sudo systemctl stop postgresql 2>/dev/null
sudo systemctl disable postgresql 2>/dev/null
sudo pg_dropcluster --stop 18 main 2>/dev/null

echo "=== resolved versions (lever proof, Linux arm) ==="
/usr/lib/postgresql/18/bin/postgres --version || echo "FATAL: no PG18"
/usr/lib/postgresql/18/bin/pgbench --version || echo "NOTE: no pgbench"
modinfo zfs 2>/dev/null | grep -E '^(version|srcversion)' || echo "NOTE: zfs module not present (driver box, fine)"
zfs --version 2>/dev/null
uname -r
nproc
free -g | head -2
lsblk -d -o NAME,SIZE,ROTA
echo LINUXPREP_DONE
