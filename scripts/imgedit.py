#!/usr/bin/python3

import sys, struct
import os
import subprocess
import time

from nbd_client import nbd_client
from random import randint

_devnull = open('/dev/null', 'w')

# The image argument may carry a qemu "-f raw " prefix (see nbd_file); strip it
# when the plain path is needed, e.g. to stat the file.
def img_path(name):
    if name.startswith("-f raw "):
        return name[7:]
    return name

cmd = sys.argv[1]
args = sys.argv[2:]

args_offset = 512

def chs(x):
    sec_per_track = 63
    heads = 255

    c = (x // sec_per_track) // heads
    h = (x // sec_per_track) % heads
    s = x % sec_per_track + 1

    # see http://en.wikipedia.org/wiki/Master_Boot_Record
    if c > 1023:
        c = 1023
        h = 254
        s = 63

    return c, h, s

def read_chars_up_to_null(file):
    keep_reading = True
    while keep_reading:
        try:
            c = file.read(1).decode()
            if c == '\0':
                keep_reading = False
            yield c
        except ValueError:
            keep_reading = False

def read_cstr(file):
    return ''.join(read_chars_up_to_null(file))

def write_cstr(file, str):
    file.write(str.encode())
    file.write(b'\0')

class nbd_file(object):

    def __init__(self, filename):
        fileformat = []
        if filename.startswith("-f raw "):
            filename = filename[7:]
            fileformat = ['-f', 'raw']
        self._filename = filename
        self._offset = 0
        self._buf = None
        self._closed = True
        nbd_port = randint(10809, 20809)
        self._process = subprocess.Popen(["qemu-nbd", "-b", "127.0.0.1", "-p", str(nbd_port)] + fileformat + [filename], shell=False, stdout=_devnull)
        # wait for qemu-nbd to start: this thing doesn't tell anything on stdout
        while True:
            try:
                self._client = nbd_client("127.0.0.1", nbd_port)
                break
            except:
                if self._process.poll() != None:
                    raise Exception('Qemu terminated with exit code %d' % self._process.returncode)
                time.sleep(0.1)
        self._closed = False

    def __del__(self):
        self.close()

    def __enter__(self):
        return self

    def __exit__(self, type, value, traceback):
        self.close()

    def close(self):
        if self._closed:
            return
        # send disconnect to nbd server
        self._client.close()
        # wait for server to exit
        if self._process.wait():
            raise Exception('Qemu terminated with exit code %d' % self._process.returncode)
        self._closed = True

    def seek(self, offset):
        self._offset = offset

    def _sect_begin(self, offset):
        return (offset // 512) * 512

    def _offset_in_sect(self, offset):
        return offset % 512

    def _sect_size(self, offset, count):
        size = self._offset_in_sect(offset) + count
        return ((size // 512) + 1) * 512

    def read(self, count):
        sect_begin = self._sect_begin(self._offset)
        offset_in_sect = self._offset_in_sect(self._offset)
        sect_size = self._sect_size(self._offset, count)

        self._buf = self._client.read(sect_begin, sect_size)

        data = self._buf[offset_in_sect: offset_in_sect + count]

        self._offset += count

        return data

    def write(self, data):
        count = len(data)
        sect_begin = self._sect_begin(self._offset)
        offset_in_sect = self._offset_in_sect(self._offset)
        sect_size = self._sect_size(self._offset, count)

        self._buf = self._client.read(sect_begin, sect_size)

        buf = self._buf[0: offset_in_sect] + data + \
              self._buf[offset_in_sect + count:]

        self._client.write(buf, sect_begin)
        self._client.flush()

        self._offset += count

        return count

    def size(self):
        self._client.size()

if cmd == 'setargs':
    img = args[0]
    args = args[1:]
    argstr = str.join(' ', args)
    with nbd_file(img) as f:
        f.seek(args_offset)
        write_cstr(f, argstr)
elif cmd == 'getargs':
    img = args[0]
    with nbd_file(img) as f:
        f.seek(args_offset)
        print(read_cstr(f))
elif cmd == 'setsize':
    img = args[0]
    size = int(args[1])
    block_size = 32 * 1024
    blocks = (size + block_size - 1) // block_size
    f = nbd_file(img)
    f.seek(0x10)
    f.write(struct.pack('H', blocks))
    f.close()
elif cmd == 'setsize_aarch64':
    img = args[0]
    size = int(args[1])
    f = nbd_file(img)
    f.seek(0x10)
    f.write(struct.pack('<Q', size))
    # The same image is also a PE/COFF EFI application (see the _head comment
    # in arch/aarch64/preboot.S).  Four PE size fields cannot be known until
    # the kernel ELF has been concatenated onto the preboot stub, so they are
    # emitted as zero and filled in here.
    #
    # The PE header is located by reading the offset back out of _head + 0x3c
    # rather than by hardcoding it, so the layout lives in exactly one place.
    # A kernel built without the PE overlay has 0 there and is left alone,
    # which keeps this a no-op for any other arch or an older preboot.
    f.seek(0x3c)
    (pe_off,) = struct.unpack('<I', f.read(4))
    if pe_off != 0:
        f.seek(pe_off)
        if f.read(4) == b'PE\0\0':
            # *** TWO DIFFERENT SIZES, AND CONFUSING THEM IS NOT A CLEAN
            # FAILURE. ***
            #
            # `size` is the MEMORY footprint from image_start: it includes the
            # kernel's .bss, so it is larger than the file.  It is the right
            # value for SizeOfImage and the section's VirtualSize, which tell
            # the firmware how much memory to reserve.
            #
            # SizeOfRawData and SizeOfCode describe BYTES PRESENT IN THE FILE.
            # Setting them from `size` makes the firmware read past EOF; EDK2
            # then rejects the image with "Unsupported" and the boot manager
            # reports only "No bootable option or device was found", which
            # looks like a missing or mis-named file rather than a bad header.
            file_size = os.path.getsize(img_path(img))
            mem_size = size
            raw_size = file_size - 0x1000
            coff = pe_off + 4
            # Read SizeOfOptionalHeader rather than assuming it: the section
            # table follows the optional header, whose length depends on
            # NumberOfRvaAndSizes.  Hardcoding it is how you end up patching
            # the middle of a data directory, corrupting the image without
            # changing its size.
            f.seek(coff + 16)
            (opt_size,) = struct.unpack('<H', f.read(2))
            opt = coff + 20
            sec = opt + opt_size
            f.seek(opt + 4)                 # SizeOfCode      (in the file)
            f.write(struct.pack('<I', raw_size))
            f.seek(opt + 56)                # SizeOfImage     (in memory)
            f.write(struct.pack('<I', mem_size))
            f.seek(sec + 8)                 # VirtualSize     (in memory)
            f.write(struct.pack('<I', mem_size - 0x1000))
            f.seek(sec + 16)                # SizeOfRawData   (in the file)
            f.write(struct.pack('<I', raw_size))
    f.close()
elif cmd == 'setpartition':
    img = args[0]
    partition = int(args[1])
    start = int(args[2])
    size = int(args[3])
    partition = 0x1be + ((partition - 1) * 0x10)
    f = nbd_file(img)

    fsize = f.size()

    cyl, head, sec = chs(start // 512)
    cyl_end, head_end, sec_end = chs((start + size) // 512)

    f.seek(partition + 1)
    f.write(struct.pack('B', head))
    f.seek(partition + 5)
    f.write(struct.pack('B', head_end))

    f.seek(partition + 2)
    f.write(struct.pack('H', (cyl << 6) | sec))
    f.seek(partition + 6)
    f.write(struct.pack('H', (cyl_end << 6) | sec_end))

    system_id = 0x83
    f.seek(partition + 4)
    f.write(struct.pack('B', system_id))

    f.seek(partition + 8)
    f.write(struct.pack('I', start // 512))
    f.seek(partition + 12)
    f.write(struct.pack('I', size // 512))
    f.close()
elif cmd == 'getpartition_offset':
    img = args[0]
    partition = int(args[1])
    partition = 0x1be + ((partition - 1) * 0x10)
    with nbd_file(img) as f:
        f.seek(partition + 8)
        (offset,) = struct.unpack("I", f.read(4))
        print(offset * 512)
