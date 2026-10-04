#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual queue admission/deinit/flush; host IRQ/thread shims, not guest proof.
Optional source argument pins the previous reviewed candidate negative.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'bsd/sys/dev/random/random_harvestq.cc'
source = re.sub(r'^#include .*$', '', path.read_text(), flags=re.M)
fixture = (root / 'tests/tst-harvest-stop.cc.inc').read_text()
assert fixture.count('// KERNEL_CODE') == 1
with tempfile.TemporaryDirectory(prefix='harvest-life-') as tmp:
    src = Path(tmp) / 'test.cc'
    src.write_text(fixture.replace('// KERNEL_CODE', source))
    exe = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + ['-std=gnu++17', '-O1', '-g',
        '-Wall', '-Wextra', '-pthread', str(src), '-o', str(exe)] +
        shlex.split(os.getenv('TEST_CFLAGS', '')), check=True, timeout=120)
    subprocess.run([str(exe)], check=True, timeout=15)
