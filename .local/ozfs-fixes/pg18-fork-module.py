from osv.modules.filemap import FileMap
from osv.modules import api

# Stock musl PostgreSQL 18.4 built as an OSv PIE, running with /data on a ZFS
# pool backed by a virtio-blk disk on local NVMe (fs=zfs conf_zfs=openzfs
# conf_fork=1).  Map the whole install tree to its ORIGINAL build path so
# RUNPATH (/b/.local/pg18/install/lib) and pkglibdir/sharedir resolve unchanged.
_install = '/b/.local/pg18/install'

usr_files = FileMap()
usr_files.add(_install + '/bin').to(_install + '/bin')
usr_files.add(_install + '/lib').to(_install + '/lib')
usr_files.add(_install + '/share').to(_install + '/share')

# cpiod.so: used once at Phase-A seed time to stream the host-initdb'd cluster
# into the ZFS pgdata pool mounted at /data.
usr_files.add('${OSV_BUILD_PATH}/tools/cpiod/cpiod.so').to('/tools/cpiod.so')

# ZFS in-kernel driver (libsolaris.so) + userspace CLI (zpool.so/zfs.so) so the
# guest can create/import the pgdata pool and mount /data on it.
api.require('zfs')
api.require('zfs-tools')

# Default run: /data is mounted from the imported pgdata pool (boot with
# --extra-zfs-pools).  Phase-A init (zpool create + initdb) is driven via a
# --append override at boot time, so it is not baked in here.
# TCP-only: AF_UNIX unsupported on OSv, so unix_socket_directories='' in conf.
_cmd = _install + '/bin/postgres -D /data'

default = api.run(_cmd)
