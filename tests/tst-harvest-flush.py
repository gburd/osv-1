#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Compile actual harvest worker/flush; deterministic old ack-before-drain race.
Host scheduler/ring shims are not kernel/IRQ proof. Run remotely on build host.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'bsd/sys/dev/random/random_harvestq.cc').read_text()
old = 'int random_kthread_control = 0;' in source
if old:
    soft = (root / 'bsd/sys/dev/random/randomdev_soft.cc').read_text()
    start = soft.index('\nrandomdev_flush_reseed(void)\n{')
    end = soft.index('\n}', start) + 2
    source += '\nstatic void' + soft[start:end]
    flush = 'randomdev_flush_reseed()'
    requested = 'random_kthread_control == 1'
else:
    flush = 'random_harvestq_flush()'
    requested = 'flush_request.load() != flush_ack.load()'
source = re.sub(r'^#include .*$', '', source, flags=re.M)
fixture = (root / 'tests/tst-harvest-flush.cc.inc').read_text()
assert fixture.count('// KERNEL_CODE') == 1
if old:
    fixture = fixture.replace('    stopping.store(false);', '')
fixture = fixture.replace('// KERNEL_CODE', source)
fixture = fixture.replace('FLUSH_CALL', flush).replace('REQUESTED', requested)
fixture = fixture.replace('TEST_STOP', 'true' if os.getenv('TEST_STOP') == '1' else 'false')
fixture = fixture.replace('STOP_CHECK', 'assert(stop_done && random_harvestq_flush() == ENXIO);'
    if not old else 'assert(stop_done);')
with tempfile.TemporaryDirectory(prefix='harvest-test-') as tmp:
    src = Path(tmp) / 'test.cc'
    src.write_text(fixture)
    exe = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + ['-std=gnu++17', '-O1', '-g',
        '-Wall', '-Wextra', '-pthread', str(src), '-o', str(exe)] +
        shlex.split(os.getenv('TEST_CFLAGS', '')), check=True, timeout=120)
    subprocess.run([str(exe)], check=True, timeout=15)
