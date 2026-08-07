#!/usr/bin/env python3
# cpio_push.py -- stream a host directory tree to OSv cpiod.so over TCP (newc cpio).
# usage: cpio_push.py <srcdir> <host> <port>   (paths land under cpiod --prefix)
import os, socket, stat, sys, time

src, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])

def field(n, l): return ("%.*x" % (l, n)).encode()
def header(name, mode, size):
    nb = name.encode()
    return (b"070701" + field(0,8)+field(mode,8)+field(0,8)+field(0,8)+field(0,8)
            + field(0,8)+field(size,8)+field(0,8)+field(0,8)+field(0,8)+field(0,8)
            + field(len(nb)+1,8)+field(0,8)+nb+b"\0")

s = None
for _ in range(120):
    try:
        s = socket.socket(); s.connect((host, port)); break
    except OSError:
        if s: s.close()
        s = None; time.sleep(1)
if s is None: sys.exit("cpiod connect timeout")

def send(data):
    s.sendall(data)
    p = len(data) % 4
    if p: s.sendall(b"\0"*(4-p))

n = 0
for root, dirs, fnames in os.walk(src):
    # emit directory entries too (postgres requires empty dirs like pg_notify/)
    for d in dirs:
        dp = os.path.join(root, d)
        rel = os.path.relpath(dp, src)
        if os.path.islink(dp):
            link = os.readlink(dp)
            send(header(rel, stat.S_IFLNK, len(link))); send(link.encode())
        else:
            send(header(rel, stat.S_IFDIR | 0o700, 0))
        n += 1
    for fn in fnames:
        fp = os.path.join(root, fn)
        rel = os.path.relpath(fp, src)
        st = os.lstat(fp)
        if stat.S_ISLNK(st.st_mode):
            link = os.readlink(fp)
            send(header(rel, stat.S_IFLNK, len(link))); send(link.encode())
        else:
            send(header(rel, stat.S_IFREG | 0o644, st.st_size))
            with open(fp, "rb") as f:
                while True:
                    b = f.read(1 << 20)
                    if not b: break
                    s.sendall(b)
            p = st.st_size % 4
            if p: s.sendall(b"\0"*(4-p))
        n += 1
send(header("TRAILER!!!", 0, 0))
s.close()
print("pushed %d files" % n)
