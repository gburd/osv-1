#!/bin/bash
# Driver bootstrap: HammerDB 6.0 + postgres client on Ubuntu 24.04
set -x
exec > /tmp/drv-setup.log 2>&1
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client-16 python3 python3-pip curl jq bc || \
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-client python3 python3-pip curl jq bc
cd /opt
sudo curl -fL -o hdb.tar.gz https://github.com/TPC-Council/HammerDB/releases/download/v6.0/HammerDB-6.0-Prod-Lin-UBU24.tar.gz
ls -l hdb.tar.gz
sudo tar xzf hdb.tar.gz
ls -d /opt/HammerDB*
sudo chown -R ubuntu:ubuntu /opt/HammerDB-6.0
/opt/HammerDB-6.0/hammerdbcli <<<'puts [hdb_version]; quit' 2>&1 | tail -5
echo DRV_SETUP_DONE
