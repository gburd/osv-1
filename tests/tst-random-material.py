#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual resume hook + harvest constructor; timing is controlled, NOT entropy.
Optional argument selects baseline drivers/random.cc for negative control.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'drivers/random.cc'
text = source.read_text()
marker = 'void reseed_on_resume()\n{'
assert text.count(marker) == 1
start = text.index(marker)
end = text.index('{', start) + 1
depth = 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
hook = text[start:end]
assert hook.count('::clock::get()') == 2
hook = hook.replace('::clock::get()', 'test_clock::get()')
headers = '\n'.join(re.sub(r'^#include .*$', '', (root / p).read_text(), flags=re.M)
    for p in ['bsd/sys/sys/random.h', 'bsd/sys/dev/random/randomdev_soft.h'])
fixture = r'''
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>
#include <sys/types.h>
using u64 = uint64_t;
#define _KERNEL
namespace test_clock {
struct clock { u64 time() { return 16; } u64 uptime() { return 32; } };
clock* get() { static clock c; return &c; }
}
namespace processor { u64 rdtsc() { return 48; } }
// HEADERS
static std::vector<uint8_t> material;
static unsigned rekeys;
void random_process_event(struct harvest* event) {
    assert(event->bits == 0 && event->size <= HARVESTSIZE);
    material.insert(material.end(), event->entropy, event->entropy + event->size);
}
void random_harvestq_internal(uint64_t c, const void* buf, unsigned n, unsigned bits, esource src) {
    struct harvest event(c, buf, n, bits, src);
    random_process_event(&event);
}
static void rekey() { ++rekeys; }
static struct { void(*reseed)(); } adaptor{rekey};
static auto* random_adaptor = &adaptor;
static std::atomic<bool> _reseed_ready{false};
// HOOK
int main() {
    reseed_on_resume();
    assert(material.empty() && rekeys == 0);
    _reseed_ready.store(true);
    reseed_on_resume();
    const uint64_t expected[] = {16, 48, 32};
    assert(material.size() == sizeof(expected) && "resume timing truncated");
    assert(memcmp(material.data(), expected, sizeof(expected)) == 0);
    assert(rekeys == 1);
    puts("PASS: actual resume hook processes all 24 timing bytes with zero credit");
}
'''
with tempfile.TemporaryDirectory(prefix='resume-material-') as tmp:
    src = Path(tmp) / 'test.cc'
    src.write_text(fixture.replace('// HEADERS', headers).replace('// HOOK', hook))
    exe = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + ['-std=gnu++17', '-O1', '-g',
        '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)] +
        shlex.split(os.getenv('TEST_CFLAGS', '')), check=True, timeout=120)
    subprocess.run([str(exe)], check=True, timeout=15)
