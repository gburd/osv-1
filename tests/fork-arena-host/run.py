#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd
# SPDX-License-Identifier: BSD-2-Clause
"""Supplemental exact-source host checks, NOT OSv scheduler/COW validation.

Only platform includes are substituted. Scheduling hooks live solely in this
test TU: owner/end publication, pre-carve CAS, Treiber next/descriptor read,
and the platform mapping/lock boundary. --source accepts old source for RED.
--remove-pop-lock is a deliberate negative: descriptor-lock must fail uniqueness.
"""
import argparse
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=pathlib.Path, default=root / 'core/fork_arena.cc')
p.add_argument('--sanitize', default='')
p.add_argument('--remove-pop-lock', action='store_true',
               help='negative control: remove only descriptor pop locking')
p.add_argument('--mmu-source', type=pathlib.Path, default=root / 'core/mmu.cc')
p.add_argument('cases', nargs='*', default=['publication', 'collision', 'boundary-cas', 'publish-free', 'boundaries', 'threads', 'null', 'vma-order', 'aba', 'readonly-free', 'atomic-touch', 'recycle-stress', 'cache-bound', 'descriptor-lock'])
a = p.parse_args()
source = a.source.read_text()
if a.remove_pop_lock:
    site = 'void *pop(unsigned idx)\n    {\n        SCOPE_LOCK(recycle_lock);'
    assert source.count(site) == 1, 'unknown descriptor pop lock site'
    source = source.replace(site, site.replace('SCOPE_LOCK(recycle_lock);',
                           '// Negative control: pop lock removed.'), 1)
site = 'auto n = heads[idx];'
if site in source:
    assert source.count(site) == 1
    source = source.replace(site, site + '\n        host::descriptor_pause();', 1)
else:
    assert 'descriptor-lock' not in a.cases, 'descriptor-lock requires identity descriptors'
old = 'expect, as, std::memory_order_acq_rel)) {'
new = 'g_as_freelists[i].owner.store(as, std::memory_order_release);'
assert (old in source) != (new in source), 'unknown owner publication site'
site = old if old in source else new
source = source.replace(site, site + '\n            host::published();', 1)
site = 'free_node *next = head->next;'
if site in source:
    source = source.replace(site, site + '\n            host::pop_read();', 1)
else:
    site = 'chunk = fl->pop(idx);'
    assert source.count(site) == 1
    source = source.replace(site, 'host::pop_read();\n        ' + site, 1)
site = 'if (fl->ovf_next.compare_exchange_weak(c, c + class_size,'
assert source.count(site) == 1
source = source.replace(site, 'host::carve_read();\n        ' + site, 1)
site = re.search(r'fl->ovf_end.store\([^;]+std::memory_order_release\);', source)
assert site
source = source[:site.end()] + '\n    host::end_published();' + source[site.end():]
mmu_source = a.mmu_source.read_text()
start = mmu_source.index('std::string procfs_maps()')
end = mmu_source.index('\n}\n', start) + 2
procfs = mmu_source[start:end]
strip = lambda s: re.sub(r'^#include[^\n]*', '', s, flags=re.M)
with tempfile.TemporaryDirectory(prefix='fork-arena-host-') as tmp:
    tu = pathlib.Path(tmp) / 'arena.cc'
    exe = pathlib.Path(tmp) / 'arena'
    tu.write_text((root / 'tests/fork-arena-host/platform.hh').read_text() + '\n' +
                  strip((root / 'include/osv/fork_arena.hh').read_text()) + '\n' +
                  '#line 1 "core/fork_arena.cc"\n' + strip(source) + '\n' +
                  (root / 'tests/fork-arena-host/vma.hh').read_text() + '\n' +
                  'namespace mmu {\n' + procfs + '\n}\n' +
                  (root / 'tests/fork-arena-host/check.cc').read_text())
    cmd = ['g++', '-std=gnu++17', '-g', '-O1', '-Wall', '-Wextra', '-Werror',
           '-pthread', str(tu), '-o', str(exe)]
    if a.sanitize:
        cmd += ['-fsanitize=' + a.sanitize, '-fno-omit-frame-pointer']
    print(' '.join(cmd), flush=True)
    subprocess.run(cmd, check=True)
    failed = False
    for case in a.cases:
        try:
            result = subprocess.run([str(exe), case], timeout=10)
            print(case, 'exit', result.returncode, flush=True)
            failed |= result.returncode != 0
        except subprocess.TimeoutExpired:
            print(case, 'FAIL: timeout (possible lock inversion)', flush=True)
            failed = True
    raise SystemExit(int(failed))
