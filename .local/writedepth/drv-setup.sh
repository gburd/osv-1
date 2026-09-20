#!/bin/bash
# Debian driver bootstrap: install HammerDB 6.0 + a postgres client for probing.
set -x
exec > /tmp/drv-setup.log 2>&1 || true
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y wget curl postgresql-client jq
cd /opt
if [ ! -d /opt/HammerDB-6.0 ]; then
  sudo wget -q https://github.com/TPC-Council/HammerDB/releases/download/v6.0/HammerDB-6.0-Linux.tar.gz -O /opt/hdb.tgz \
    || sudo curl -sL https://github.com/TPC-Council/HammerDB/releases/download/v6.0/HammerDB-6.0-Linux.tar.gz -o /opt/hdb.tgz
  sudo tar xzf /opt/hdb.tgz -C /opt
  sudo chown -R admin:admin /opt/HammerDB-6.0
fi
/opt/HammerDB-6.0/hammerdbcli --version 2>&1 | head -3 || ls /opt/HammerDB-6.0
echo DRV_SETUP_DONE
