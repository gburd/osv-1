#!/usr/bin/env python3
# Resolve every UNDETERMINED PR by asking WHY the diff applies in neither
# direction. UNDETERMINED is not a verdict, it is "the cheap test cannot tell";
# each case has exactly one of a small number of real causes, and they are
# distinguishable mechanically.
#
#   STRUCTURE-MISMATCH  a file the diff touches does not exist in this base
#                       (PR authored against the restructured open_zfs tree)
#   BASE-DIVERGED       the files exist but the base carries a different version
#                       of the same region; per-hunk reverse tells how much
#   MERGED-BY-HAND      I applied it with a manual resolution, so neither the
#                       forward nor reverse diff matches verbatim
#
# Copyright (C) 2026 Greg Burd
import subprocess
import sys

WT = "/home/gburd/ws/osv/.local/projmax/wt-compose"
UNDET = """1513 1512 1511 1510 1509 1506 1505 1503 1502 1499 1496 1495 1494 1493
1492 1488 1487 1484 1483 1482 1478 1477 1475 1472 1470 1467 1464 1463 1461 1459
1458 1456 1455 1449 1445 1444 1442 1441 1439 1438 1424""".split()

# PRs I applied with a hand resolution this run
HAND = {"1494", "1496"}


def sh(*a, **kw):
    return subprocess.run(a, capture_output=True, text=True, **kw)


prlist = {}
for line in open("/home/gburd/ws/osv/.local/projmax/prlist.txt"):
    p = line.split(None, 5)
    if len(p) >= 6:
        prlist[p[0]] = (p[1], p[4], p[5].strip())

rows = []
for n in UNDET:
    oid, ref, title = prlist.get(n, ("", "", "?"))
    patch = f"/tmp/pmdiff-{n}.patch"
    files = sh("git", "-C", "/home/gburd/ws/osv", "diff", "--name-only",
               f"upstream/master...{oid}").stdout.split()
    missing = [f for f in files if sh("test", "-e", f"{WT}/{f}").returncode != 0]
    # per-hunk reverse count, reusing the earlier measurement where present
    try:
        h = open(f"/home/gburd/ws/osv/.local/projmax/presence.txt.hunk-{n}").read()
        rev = int([x for x in h.split("\n") if x.startswith("HUNKS_REVERSE")][-1].split()[1])
        tot = int([x for x in h.split("\n") if x.startswith("HUNKS_TOTAL")][-1].split()[1])
    except (OSError, IndexError):
        rev = tot = -1

    if n in HAND:
        cause = "MERGED-BY-HAND"
    elif missing:
        cause = "STRUCTURE-MISMATCH"
    elif rev > 0:
        cause = "BASE-DIVERGED-PARTIAL"
    else:
        cause = "BASE-DIVERGED-NONE"

    rows.append((n, cause, len(files), len(missing), rev, tot, missing[:2], title))

print(f"{'PR':<6}{'CAUSE':<24}{'files':>6}{'missing':>8}{'rev/tot':>10}  first-missing-path")
for n, cause, nf, nm, rev, tot, mp, title in rows:
    rt = f"{rev}/{tot}" if rev >= 0 else "-"
    print(f"{n:<6}{cause:<24}{nf:>6}{nm:>8}{rt:>10}  {mp[0] if mp else ''}")

from collections import Counter
print()
for k, v in Counter(r[1] for r in rows).most_common():
    print(f"  {k}: {v}")
