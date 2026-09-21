#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd
#
# Per-hunk reverse-apply presence test. Splits a unified diff into one
# single-hunk patch per hunk and asks `git apply -R --check` about each, in a
# worktree checked out at the candidate base. This is the only test that has
# given correct answers on this campaign: a whole-diff apply -R answers
# "all-or-nothing", and keyword greps answer neither.
import subprocess
import sys

wt, patch = sys.argv[1], sys.argv[2]
lines = open(patch, encoding="utf-8", errors="surrogateescape").read().split("\n")

# group into per-file blocks, then per-hunk patches carrying that file's header
files = []
cur = None
for ln in lines:
    if ln.startswith("diff --git "):
        cur = {"hdr": [ln], "hunks": []}
        files.append(cur)
    elif cur is None:
        continue
    elif ln.startswith("@@"):
        cur["hunks"].append([ln])
    elif cur["hunks"]:
        cur["hunks"][-1].append(ln)
    else:
        cur["hdr"].append(ln)

total = ok = 0
detail = []
for f in files:
    name = f["hdr"][0].split(" b/")[-1]
    # a pure add/delete/mode-only block with no hunks: presence == file exists
    if not f["hunks"]:
        continue
    for i, h in enumerate(f["hunks"]):
        total += 1
        p = "\n".join(f["hdr"] + h)
        if not p.endswith("\n"):
            p += "\n"
        r = subprocess.run(
            ["git", "-C", wt, "apply", "-R", "--check", "-"],
            input=p.encode("utf-8", "surrogateescape"),
            capture_output=True,
        )
        if r.returncode == 0:
            ok += 1
            detail.append(f"  REV  {name} hunk{i+1} {h[0][:60]}")
        else:
            detail.append(f"  MISS {name} hunk{i+1} {h[0][:60]}")

print("\n".join(detail))
print(f"HUNKS_TOTAL {total}")
print(f"HUNKS_REVERSE {ok}")
