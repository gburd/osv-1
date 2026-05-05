from osv.modules.api import *

# ZFS kernel module (libsolaris.so)
require('zfs')

# ZFS userspace tools: zpool.so, zfs.so, libzfs.so, libuutil.so
require('zfs-tools')

run = []
