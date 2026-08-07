#!/usr/bin/env python3
"""git rebase sequence editor: mark build-nix, pagecache-vfs, openzfs as 'edit'."""
import sys

TARGETS = ("d34ac676", "aa053444", "1d06a7c2")
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
out = []
for ln in lines:
    if ln.startswith("pick ") and any(t in ln for t in TARGETS):
        out.append("edit " + ln[len("pick "):])
    else:
        out.append(ln)
with open(path, "w") as f:
    f.writelines(out)
