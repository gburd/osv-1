#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual VFS/virtiofs bodies: FUSE_READ flags must match read-only FUSE_OPEN.
Adapted from the independent RNG U1-1 boundary probe. No daemon is exercised.
Locking, allocation, DAX outcome and transport are host shims, not kernel proof.
Optional source root selects an archived candidate for negative controls.
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
    text = path.read_text()
    assert text.count(marker) == 1
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


vnops = root / 'fs/virtiofs/virtiofs_vnops.cc'
flags = '\n'.join(re.findall(r'^#define IO_.*$', (root / 'include/osv/vnode.h').read_text(), re.M))
open_flags, = re.findall(r'^static constexpr uint32_t OPEN_FLAGS = .*;', vnops.read_text(), re.M)
fixture = r'''
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstddef>
#include <functional>
#include <memory>
#include <utility>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include "fuse_kernel.h"
using u64 = uint64_t; using u32 = uint32_t;
// FLAGS
static constexpr int VREG=1, VBLK=2, VDIR=3, FOF_OFFSET=1, FWRITE=O_WRONLY|O_RDWR;
struct uio { off_t uio_offset=0; ssize_t uio_resid=1; };
namespace virtio { struct fs {}; }
struct virtiofs_inode { struct { uint64_t size=10; mode_t mode=S_IFREG; } attr; uint64_t nodeid=2; };
struct virtiofs_file_data { uint64_t file_handle; };
struct dax {
    bool fail; unsigned calls=0;
    int read(virtiofs_inode&, uint64_t, uint64_t n, uio& io) {
        ++calls;
        if (fail) return EIO;
        io.uio_resid-=n; io.uio_offset+=n; return 0;
    }
};
struct virtiofs_mount_data { virtio::fs* drv; dax* dax_mgr=nullptr; };
struct mount { void* m_data; };
struct vnode { int v_type=VREG; off_t v_size=10; void* v_data; mount* v_mount; };
struct dentry { vnode* d_vnode; };
struct file { void* f_data=nullptr; int f_flags=O_RDONLY; dentry* f_dentry; };
struct vfs_file : file { off_t f_offset=0; int read(uio*,int); };
static int file_flags(file* fp) { return fp->f_flags; }
static dentry* file_dentry(file* fp) { return fp->f_dentry; }
static void file_setdata(file* fp, void* data) { fp->f_data=data; }
static void vn_lock(vnode*) {} static void vn_unlock(vnode*) {}
namespace memory {
void* alloc_phys_contiguous_aligned(size_t n, size_t) { return malloc(n); }
void free_phys_contiguous_aligned(void* p) { free(p); }
}
#define virtiofs_debug(...) do {} while(0)
static void kprintf(const char*, ...) { assert(false); }
static unsigned open_wire_flags, read_wire_flags, reads, opens;
static std::pair<int,int> fuse_req_send_and_receive_reply(virtio::fs*, int op,
 uint64_t, fuse_open_in* args, size_t, fuse_open_out* out, size_t) {
    assert(op==FUSE_OPEN); ++opens; open_wire_flags=args->flags; out->fh=3; return {0,0};
}
static std::pair<int,int> fuse_req_send_and_receive_reply(virtio::fs*, int op,
 uint64_t, fuse_read_in* args, size_t, void*, size_t) {
    assert(op==FUSE_READ); assert(args->fh==3); ++reads; read_wire_flags=args->flags; return {1,0};
}
static int uiomove(void*, unsigned n, uio* io) { io->uio_resid-=n; io->uio_offset+=n; return 0; }
// OPEN
// FALLBACK
// READ
#define VOP_READ(vp,fp,io,flags) virtiofs_read(vp,fp,io,flags)
// VFS
int main() {
    virtio::fs drv; virtiofs_mount_data data{&drv}; mount m{&data};
    virtiofs_inode inode; vnode vp{VREG,10,&inode,&m}; dentry dent{&vp};
    // Exhaust the three independent IO bits and fd append/sync/nonblock mixtures.
    const int fd_flags[] = {0, O_NONBLOCK, O_APPEND, O_SYNC, O_DSYNC,
        O_APPEND|O_SYNC, O_NONBLOCK|O_APPEND, O_NONBLOCK|O_SYNC,
        O_NONBLOCK|O_DSYNC, O_NONBLOCK|O_APPEND|O_SYNC};
    const int io_flags[] = {0, IO_NONBLOCK, IO_APPEND, IO_SYNC,
        IO_APPEND|IO_SYNC, IO_NONBLOCK|IO_APPEND, IO_NONBLOCK|IO_SYNC,
        IO_NONBLOCK|IO_APPEND|IO_SYNC};
    for (int fd_flag : fd_flags) {
        vfs_file f; f.f_flags=O_RDONLY|fd_flag; f.f_dentry=&dent;
        assert(virtiofs_open(&f)==0);
        assert(open_wire_flags==0 && "virtiofs read-only OPEN contract changed");
        for (int mode=0; mode<3; ++mode) {
            dax dax_state{mode==1}; data.dax_mgr=mode ? &dax_state : nullptr;
            for (int positioned : {0, FOF_OFFSET}) {
                uio io; f.f_offset=0; reads=0;
                assert(f.read(&io,positioned)==0 && io.uio_resid==0);
                assert(reads==(mode==2 ? 0u : 1u));
                if (reads) {
                    printf("VFS fd=%d positioned=%d dax=%d FUSE_READ.flags=%u FUSE_OPEN.flags=%u\n",
                        fd_flag, positioned, mode, read_wire_flags, open_wire_flags);
                    fflush(stdout);
                    assert(read_wire_flags==open_wire_flags && "vnode IO flags leaked into FUSE open-flags field");
                }
            }
            for (int io_flag : io_flags) {
                uio io; reads=0;
                assert(virtiofs_read(&vp,&f,&io,io_flag)==0 && io.uio_resid==0);
                assert(reads==(mode==2 ? 0u : 1u));
                if (reads) {
                    printf("VOP io=%d dax=%d FUSE_READ.flags=%u FUSE_OPEN.flags=%u\n",
                        io_flag, mode, read_wire_flags, open_wire_flags);
                    fflush(stdout);
                    assert(read_wire_flags==open_wire_flags && "vnode IO flags leaked into FUSE open-flags field");
                }
            }
            assert(dax_state.calls==(mode ? 10u : 0u));
        }
        delete static_cast<virtiofs_file_data*>(f.f_data);
    }
    assert(opens==10);
    puts("PASS: actual FUSE_OPEN/READ flags agree across VFS and IO flag mixtures, DAX absent/failure/success");
}
'''
text = fixture.replace('// FLAGS', flags + '\n' + open_flags)
for token, path, marker in (
    ('// OPEN', vnops, 'static int virtiofs_open('),
    ('// FALLBACK', vnops, 'static int virtiofs_read_fallback('),
    ('// READ', vnops, 'static int virtiofs_read(struct'),
    ('// VFS', root / 'fs/vfs/vfs_fops.cc', 'int vfs_file::read('),
):
    text = text.replace(token, body(path, marker))
with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'check.cc').write_text(text)
    subprocess.run(shlex.split(os.environ.get('CXX', 'c++')) + [
        '-std=gnu++17', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
        *shlex.split(os.environ.get('CXXFLAGS', '')),
        '-I' + str(root / 'fs/virtiofs'), str(tmp / 'check.cc'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True, timeout=30)
