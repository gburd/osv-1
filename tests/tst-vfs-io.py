#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Run actual RNG gates and OpenZFS IO bridges, not translation replicas.
Host shims provide locking, sleep interruption and bytes; no entropy claim.
Optional source root permits a pure-master negative without header edits.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]


def body(path, marker):
    text = (root / path).read_text()
    assert text.count(marker) == 1
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


flags = '\n'.join(re.findall(r'^#define IO_.*$', (root / 'include/osv/vnode.h').read_text(), re.M))
fixture = r'''
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
// FLAGS
#ifdef NDEBUG
#error Assertions must be enabled
#endif
// Master has no IO_NONBLOCK. This is test input, not a production definition.
#ifdef IO_NONBLOCK
constexpr int nonblock = IO_NONBLOCK;
#else
constexpr int nonblock = 8;
#endif
constexpr int PAGE_SIZE=4096, PUSER=0, PCATCH=0;
struct device {};
struct uio { long uio_resid; };
static int locks, sleeps, reads, random_reseed_mtx;
static void mtx_lock(int*) { ++locks; }
static void mtx_unlock(int*) {}
#define debug(...) do {} while (0)
static int msleep(void*, int*, int, const char*, int) { ++sleeps; return EINTR; }
static int uiomove(void*, int n, uio* io) { io->uio_resid-=n; return 0; }
static int output(void*, int n) { ++reads; return n; }
struct adaptor { int seeded; int (*block)(int); int (*read)(void*,int); };
static adaptor random_context{0,nullptr,output};
static adaptor* random_adaptor=&random_context;
// BLOCK
// READ
constexpr int VREG=1, VDIR=2, UIO_DIRECT=1, UIO_READ=0, UIO_WRITE=1;
struct vnode { int v_type=VREG; long v_size=1; };
struct file { int f_flags=0; };
struct znode_t { long z_size=1; };
struct zfs_uio_t { int uio_extflg=0; };
static znode_t zn;
static int seen_zfs;
#define VTOZ(vp) (&zn)
#define ZTOZSB(zp) (zp)
#define SET_ERROR(e) (e)
static int file_flags(file* fp) { return fp->f_flags; }
static bool zfs_is_readonly(znode_t*) { return false; }
static void zfs_uio_init(zfs_uio_t*,uio*) {}
static void zfs_uio_free_dio_pages(zfs_uio_t*,int) {}
static int zfs_read(znode_t*,zfs_uio_t*,int flags,void*) { seen_zfs=flags; return 0; }
static int zfs_write(znode_t*,zfs_uio_t*,int flags,void*) { seen_zfs=flags; return 0; }
// ZFS_READ
// ZFS_WRITE
int main() {
    random_context.block=randomdev_block;
    for (int io : {nonblock, nonblock|IO_DIRECT, nonblock|IO_SYNC|IO_APPEND|IO_DIRECT}) {
        uio u{1}; locks=sleeps=reads=0;
        const int error=random_read(nullptr,&u,io);
        assert(error==EAGAIN && "nonblocking random read did not return EAGAIN");
        assert(u.uio_resid==1 && reads==0 && sleeps==0 && locks==1);
    }
    for (int io : {0, IO_DIRECT, IO_APPEND|IO_SYNC}) {
        uio u{1}; locks=sleeps=reads=0;
        assert(random_read(nullptr,&u,io)==EINTR);
        assert(sleeps==1 && reads==0 && locks==1);
    }
    random_context.seeded=1;
    for (int io : {0, IO_DIRECT, nonblock, nonblock|IO_DIRECT}) {
        uio u{1}; locks=sleeps=reads=0;
        assert(random_read(nullptr,&u,io)==0 && u.uio_resid==0);
        assert(locks==1 && sleeps==0 && reads==2);
    }
    for (int bits=0; bits<16; ++bits) {
        const int io=(bits&1 ? nonblock : 0) | (bits&2 ? IO_DIRECT : 0)
            | (bits&4 ? IO_APPEND : 0) | (bits&8 ? IO_SYNC : 0);
        vnode vp; uio u{1};
        assert(zfs_vop_write(&vp,&u,io)==0);
        const int expected=(bits&2 ? O_DIRECT : 0) | (bits&4 ? O_APPEND : 0)
            | (bits&8 ? O_SYNC : 0);
        assert(seen_zfs==expected && "nonblocking selected a different OpenZFS write mode");
        for (int fd_bits=0; fd_bits<4; ++fd_bits) {
            file fp{(fd_bits&1 ? O_DIRECT : 0) | (fd_bits&2 ? O_DSYNC : 0) | O_NONBLOCK};
            assert(zfs_vop_read(&vp,&fp,&u,io)==0);
            assert(seen_zfs==((fd_bits&1 ? O_DIRECT : 0) | (fd_bits&2 ? O_SYNC : 0)));
        }
    }
    puts("PASS: actual OpenZFS bridges preserve direct/append/sync independently of nonblocking");
    puts("PASS: actual random read/gate translates nonblocking independently of direct IO");
}
'''
text = fixture.replace('// FLAGS', flags)
text = text.replace('// BLOCK', body('bsd/sys/dev/random/randomdev_soft.cc', 'static int\nrandomdev_block('))
text = text.replace('// READ', body('drivers/random.cc', 'static int\nrandom_read('))
for token, marker in (('// ZFS_READ', 'static int\nzfs_vop_read('),
                      ('// ZFS_WRITE', 'static int\nzfs_vop_write(')):
    text = text.replace(token, body('modules/open_zfs/osv/module/os/osv/zfs/zfs_vnops_os.c', marker))
with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'check.cc'
    source.write_text(text)
    exe = Path(tmp) / 'check'
    subprocess.run(shlex.split(os.environ.get('CXX', 'c++')) + [
        '-std=gnu++17', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
        '-O1', '-g', *shlex.split(os.environ.get('CXXFLAGS', '')),
        str(source), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True, timeout=30)
