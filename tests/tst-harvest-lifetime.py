#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual queue admission/deinit/flush; host IRQ/thread shims, not guest proof.
Optional source argument pins the previous reviewed candidate negative.
Default cases are nonfatal; TEST_CASES=reinit checks the exact production panic.
"""
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'bsd/sys/dev/random/random_harvestq.cc'
source = re.sub(r'^#include .*$', '', path.read_text(), flags=re.M)
fixture = (root / 'tests/tst-harvest-lifetime.cc.inc').read_text()
assert fixture.count('// KERNEL_CODE') == 1
# Old candidate's flush has void return. Same test must compile both snapshots.
fixture = fixture.replace('FLUSH_CHECK', 'assert(random_harvestq_flush() == ENXIO);'
    if 'int\nrandom_harvestq_flush' in source else 'random_harvestq_flush();')
with tempfile.TemporaryDirectory(prefix='harvest-life-') as tmp:
    src = Path(tmp) / 'test.cc'
    src.write_text(fixture.replace('// KERNEL_CODE', source))
    exe = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + ['-std=gnu++17', '-O1', '-g',
        '-Wall', '-Wextra', '-pthread', str(src), '-o', str(exe)] +
        shlex.split(os.getenv('TEST_CFLAGS', '')), check=True, timeout=120)
    for case in os.getenv('TEST_CASES', 'producer full late flush').split():
        if case == 'reinit':
            result = subprocess.run([str(exe), case], capture_output=True, text=True, timeout=15)
            print(result.stdout, end='')
            print(result.stderr, end='', file=sys.stderr)
            if (result.returncode != -signal.SIGABRT or
                    result.stderr.splitlines() != [
                        'PANIC: harvest queue reinitialization is not supported']):
                raise RuntimeError('reinit did not reach the expected production panic')
            print('PASS: queue repeat init reached the exact production panic')
        else:
            subprocess.run([str(exe), case], check=True, timeout=15)
