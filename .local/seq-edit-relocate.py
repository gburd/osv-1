#!/usr/bin/env python3
"""git rebase sequence editor: mark the relocation-target commits as 'edit'.

Round 3 (the last trapped musl compile-enabler):
  musl-1.2  46ebcb8d  Makefile: __map_file.o += -Wno-incompatible-pointer-types
                      (struct kstat* vs struct stat* under the 1.2.1 bump).
  (openzfs needs NO edit stop: three-way merge auto-drops the now-redundant
   __map_file.o hunk when it replays onto the amended parent.)
"""
import sys

TARGETS = ("46ebcb8d",)
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
