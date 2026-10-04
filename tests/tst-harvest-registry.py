#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual live registry, registration and adaptor-init bodies; host lock shims.
Checks callback lifetime, no registry lock reset/destruction and exact one-shot
adaptor panic. Does not model IRQ primitives or claim device unload support.
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
base = root / 'bsd/sys'
def clean(path):
    return re.sub(r'^#include .*$', '', (base / path).read_text(), flags=re.M)
def function(path, name):
    text = (base / path).read_text()
    marker = '\n' + name + '('
    assert text.count(marker) == 1
    start = text.index(marker)
    begin = text.index('{', start)
    depth, end = 1, begin + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return 'void' + text[start:end]
headers = '\n'.join(clean(p) for p in ['sys/random.h', 'dev/random/randomdev_soft.h'])
registry = clean('dev/random/live_entropy_sources.cc')
registration = '\n'.join(function('dev/random/harvest.cc', name) for name in [
    'randomdev_init_harvester', 'randomdev_deinit_harvester', 'random_harvest'])
soft = function('dev/random/randomdev_soft.cc', 'randomdev_init')
fixture = (root / 'tests/tst-harvest-registry.cc.inc').read_text()
for marker, value in [('HEADERS', headers), ('REGISTRY', registry), ('REGISTRATION', registration), ('ADAPTOR', soft)]:
    assert fixture.count('// ' + marker) == 1
    fixture = fixture.replace('// ' + marker, value)
with tempfile.TemporaryDirectory(prefix='harvest-registry-') as tmp:
    tmp = Path(tmp)
    # Use master's BSD list definitions, not a replica of the registry.
    (tmp / 'queue.h').write_text((base / 'sys/queue.h').read_text())
    src = tmp / 'test.cc'
    src.write_text(fixture)
    exe = tmp / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + [
        '-std=gnu++17', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
        '-Wno-error=unused-parameter', '-pthread',
        str(src), '-o', str(exe)] + shlex.split(os.getenv('TEST_CFLAGS', '')),
        check=True, timeout=120)
    for case in sys.argv[1:] or ['registry-init', 'registry-stop', 'deregister', 'registration', 'reinit']:
        if case == 'reinit':
            p = subprocess.run([str(exe), case], capture_output=True, text=True, timeout=15)
            print(p.stderr, end='', file=sys.stderr)
            if p.returncode != -signal.SIGABRT or p.stderr.splitlines() != [
                    'PANIC: random adaptor reinitialization is not supported']:
                raise RuntimeError('adaptor reinit did not reach exact production panic')
            print('PASS: exact adaptor reinitialization panic')
        else:
            subprocess.run([str(exe), case], check=True, timeout=15)
