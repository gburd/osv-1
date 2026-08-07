#!/usr/bin/env python3
"""Inject a diagnostic log of the actual outstanding dependency JobIds into the
Crucible downstairs check_ready(), so a wedged job names the specific dep it is
blocked on (the count-only "waiting on N deps" line is not enough to identify the
missing job). Idempotent: re-running is a no-op once the marker is present."""
import sys

F = "/scratch/crucible-test/crucible/downstairs/src/lib.rs"
MARKER = "job DIAG outstanding deps"

s = open(F).read()
if MARKER in s:
    print("already patched; no-op")
    sys.exit(0)

anchor = "            work.outstanding_deps = Some(n);\n            false"
inject = (
    "            // DIAG: log the actual outstanding dep ids, not just the count.\n"
    "            let outstanding: Vec<JobId> = work\n"
    "                .io\n"
    "                .deps()\n"
    "                .iter()\n"
    "                .filter(|&dep| !self.completed.is_complete(*dep))\n"
    "                .cloned()\n"
    "                .collect();\n"
    "            warn!(self.log, \"{} job DIAG outstanding deps: {:?}\", work.id, outstanding);\n"
    "            work.outstanding_deps = Some(n);\n"
    "            false"
)
n = s.count(anchor)
if n != 1:
    print("ERROR: anchor found %d times (expected 1)" % n)
    sys.exit(1)
s = s.replace(anchor, inject, 1)
open(F, "w").write(s)
print("patched OK")
