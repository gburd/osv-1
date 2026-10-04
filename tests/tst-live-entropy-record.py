#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd. BSD license; see LICENSE.
"""Actual live feed body/harvest layout: complete hashed-record initialization.
Poison scratch before sources run; capture exact bytes sent to event processor.
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
text = (root / 'bsd/sys/dev/random/live_entropy_sources.cc').read_text()
start = text.index('\nvoid\nlive_entropy_sources_feed(')
end = text.index('\nbool\nlive_entropy_sources_empty', start)
body = text[start:end]
marker = '\tLIST_FOREACH(les, &sources, entries) {'
assert body.count(marker) == 1
# Explicit storage poison, not an ASan claim about uninitialized reads.
body = body.replace(marker, '\tmemset(static_cast<void*>(&event), 0xa5, sizeof(event));\n' + marker)
headers = '\n'.join(re.sub(r'^#include .*$', '', (root / p).read_text(), flags=re.M)
    for p in ['bsd/sys/sys/random.h', 'bsd/sys/dev/random/randomdev_soft.h'])
fixture = r'''
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <type_traits>
#include <sys/types.h>
#define _KERNEL
#define MIN(a,b) std::min(a,b)
// HEADERS
using event_proc_f = void(*)(struct harvest*);
static unsigned expected_size, calls;
struct random_hardware_source { int(*read)(void*, int); esource source; };
struct live_entropy_sources { random_hardware_source* rsource; };
static int read_source(void* buf, int capacity) {
    assert(capacity == 16);
    // Full -> partial -> full exercises stale tail reuse, not just first use.
    expected_size = calls == 1 ? 8 : 16;
    memset(buf, 0x3c, expected_size);
    return expected_size;
}
static random_hardware_source src{read_source, RANDOM_PURE_RDRAND};
static live_entropy_sources entry{&src};
#define LIST_FOREACH(item,head,field) for (item = &entry; item; item = nullptr)
static int les_lock;
static void sx_slock(int*) {}
static void sx_sunlock(int*) {}
static uint64_t get_cyclecount() { return 0x1234; }
// BODY
static void capture(struct harvest* event) {
    static_assert(std::is_trivially_copyable<struct harvest>::value, "record layout");
    unsigned char expected[sizeof(*event)] = {};
    uintmax_t counter = 0x1234;
    unsigned bits = expected_size * 4;
    esource source = RANDOM_PURE_RDRAND;
    memcpy(expected + offsetof(struct harvest, somecounter), &counter, sizeof(counter));
    memset(expected + offsetof(struct harvest, entropy), 0x3c, expected_size);
    memcpy(expected + offsetof(struct harvest, size), &expected_size, sizeof(expected_size));
    memcpy(expected + offsetof(struct harvest, bits), &bits, sizeof(bits));
    memcpy(expected + offsetof(struct harvest, source), &source, sizeof(source));
    assert(memcmp(event, expected, sizeof(expected)) == 0 && "uninitialized tail/padding in hashed record");
    ++calls;
}
int main() {
    live_entropy_sources_feed(3, capture);
    assert(calls == 3);
    puts("PASS: actual live feed 16/8/16-byte records have zero tail and padding");
}
'''
with tempfile.TemporaryDirectory(prefix='live-record-') as tmp:
    src = Path(tmp) / 'test.cc'
    src.write_text(fixture.replace('// HEADERS', headers).replace('// BODY', body))
    exe = Path(tmp) / 'test'
    subprocess.run(shlex.split(os.getenv('CXX', 'c++')) + ['-std=gnu++17', '-O1', '-g',
        '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)] +
        shlex.split(os.getenv('TEST_CFLAGS', '')), check=True, timeout=120)
    subprocess.run([str(exe)], check=True, timeout=15)
