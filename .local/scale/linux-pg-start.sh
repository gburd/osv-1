#!/bin/bash
# Start PostgreSQL on the Ubuntu guest, MATCHED to the OSv arm's GUCs + io_method=io_uring.
# Runs inside the guest (sudo). Idempotent. Env: SB MAXCONN SYNCCOMMIT FSYNC
set -x
PGBIN=/usr/lib/postgresql/18/bin
SB="${SB:-16GB}"; MAXCONN="${MAXCONN:-400}"
SYNCCOMMIT="${SYNCCOMMIT:-on}"; FSYNC="${FSYNC:-on}"
# CONFOUND REMOVAL: the Ubuntu postgresql-18 package auto-starts its OWN cluster
# (18/main on /var/lib/postgresql/18/main) which OWNS 127.0.0.1:5432. Two effects, both
# fatal to the measurement: (1) our benchmark postmaster cannot bind the IPv4 address the
# host DNAT targets, so the driver cannot reach it at all; (2) a second live PG competes
# for CPU and the same NVMe during every Linux cell. Stop and disable it before starting
# the instance under test.
sudo systemctl stop postgresql postgresql@18-main 2>/dev/null
sudo systemctl disable postgresql postgresql@18-main 2>/dev/null
sudo pg_ctlcluster 18 main stop 2>/dev/null
for i in $(seq 1 10); do pgrep -f '18/main' >/dev/null 2>&1 || break; sleep 1; done
echo "PACKAGED_CLUSTER_RUNNING=$(pgrep -cf '18/main' 2>/dev/null || echo 0)  (expect 0)"
# ARC PARITY = EQUAL CEILING, 32GiB both arms. Measured basis (not assumed):
#   OSv arc_c_max = 32767 MB (ARCPROBE), from arc_default_max = MIN(5/8*RAM, RAM/2).
#   OSv arc_c starts at arc_c_min = allmem/32 = 2047 MB (the IDLE FLOOR) and GROWS on
#   demand (arc_adapt) -- measured climbing 2047 -> 7563 MB under a 19GB scan.
# So capping Linux at 2GiB would NOT be equality: it would pin Linux at a floor while
# OSv grows to ~32G, handicapping Linux. Equal ceiling is the honest match, and both
# arms' measured arc_c/arc_size are reported per cell so cache state is auditable.
# OSV_ZFS_ARC_MAX is ABSENT on the OSv base, so OSv's ceiling is measured, never set.
ARCMAX="${ARCMAX:-34359738368}"
echo "$ARCMAX" | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null 2>&1
sudo zpool import -f pgdata 2>/dev/null
sudo zfs mount pgdata 2>/dev/null
sudo chown -R postgres /data 2>/dev/null
# listen_addresses=0.0.0.0 (NOT '*'): $PGARGS is word-split unquoted, so a bare * would be
# GLOB-EXPANDED by the shell (PG then fell back to the config file's localhost and the
# driver could not reach it), while a quoted '*' arrives with the quotes as part of the
# value ("could not translate host name \"'*'\""). 0.0.0.0 binds all IPv4, which is exactly
# what the host DNAT to 192.168.100.2:5432 requires, and it cannot be mangled either way.
PGARGS="-c listen_addresses=0.0.0.0 -c max_connections=$MAXCONN -c shared_buffers=$SB \
-c effective_cache_size=32GB -c max_wal_size=64GB -c min_wal_size=2GB \
-c checkpoint_timeout=15min -c checkpoint_completion_target=0.9 -c log_checkpoints=on \
-c fsync=$FSYNC -c synchronous_commit=$SYNCCOMMIT -c autovacuum=on -c io_method=io_uring \
-c shared_preload_libraries=plpgsql -c max_files_per_process=200"
sudo -u postgres setsid --fork $PGBIN/postgres -D /data/pg $PGARGS >/tmp/pg.log 2>&1
sleep 5
echo "PG_STARTED pid=$(pgrep -f 'postgres -D /data/pg'|head -1)"
# LINUX-ARM RESOLVED-LEVER PROOF (the same discipline as the OSv arm: print the
# RESOLVED value, never infer it from the command line).
echo "===== LINUX RESOLVED-LEVER PROOF ====="
echo "zfs_arc_max_resolved=$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null)"
echo "arc_c_current=$(awk '/^c /{print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
echo "arc_max_kstat=$(awk '/^c_max/{print $3}' /proc/spl/kstat/zfs/arcstats 2>/dev/null)"
echo "zfs_version=$(zfs version 2>/dev/null | head -1)"
sudo zpool get -H -o property,value ashift pgdata 2>/dev/null
sudo zfs get -H -o property,value recordsize,compression,atime,sync,logbias,primarycache pgdata 2>/dev/null
echo "nr_hugepages=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)"
echo "kernel=$(uname -r)  ncpu=$(nproc)  memtotal_kB=$(awk '/MemTotal/{print $2}' /proc/meminfo)"
echo "===== END LINUX LEVER PROOF ====="
tail -3 /tmp/pg.log
