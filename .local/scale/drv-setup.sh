#!/bin/bash
# Driver setup: postgresql-client-18 (PGDG) + HammerDB 6.0. Runs on the Ubuntu c5.4xlarge.
set -x
exec > /tmp/drv-setup.log 2>&1
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y 2>&1 | tail -2
sudo apt-get install -y curl ca-certificates gnupg lsb-release wget tar 2>&1 | tail -2
# PGDG for psql 18
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update -y 2>&1 | tail -2
sudo apt-get install -y postgresql-client-18 python3 2>&1 | tail -3
echo "PSQL=$(which psql) VER=$(psql --version 2>&1)"

# HammerDB 6.0
cd /opt 2>/dev/null || { sudo mkdir -p /opt; cd /opt; }
if [ ! -d /opt/HammerDB-6.0 ]; then
  sudo wget -q https://github.com/TPC-Council/HammerDB/releases/download/v6.0/HammerDB-6.0-Linux.tar.gz -O /tmp/hdb.tgz
  echo "WGET_RC=$?  SIZE=$(stat -c %s /tmp/hdb.tgz 2>/dev/null)"
  sudo tar xzf /tmp/hdb.tgz -C /opt
  sudo chown -R ubuntu:ubuntu /opt/HammerDB-6.0 2>/dev/null || true
fi
ls -d /opt/HammerDB-6.0 2>&1
/opt/HammerDB-6.0/hammerdbcli <<< 'quit' 2>&1 | head -3
echo DRV_SETUP_DONE
