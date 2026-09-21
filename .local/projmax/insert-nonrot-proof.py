#!/usr/bin/env python3
# Copyright (C) 2026 Greg Burd
#
# Insert the NONROTPROOF / VDEVIO lever-proof instrumentation into the
# post-patch OSv vdev_disk.c, then emit a patch-series file by diffing against
# a pristine copy. Generating the patch from a real edit avoids hand-written
# hunk offsets, which is how patch 0044 shipped with a corrupt hunk count.
import re
import subprocess
import sys

F = sys.argv[1]  # path to post-patch vdev_disk.c
src = open(F).read()
orig = src

DECLS = """
/*
 * Lever-proof instrumentation for the vdev_nonrot fix (patch 0044).
 *
 * The standing campaign rule is that a lever counts as live only when its
 * RESOLVED value is printed to the console and read back per arm; source
 * presence is not proof.  printf, never debugf: debugf is verbose-gated and
 * silent by default.
 *
 * Counters are plain size_t updated without a lock.  They are diagnostic: a
 * torn read costs one wrong digit in a log line, while a lock on the bio
 * submit path would perturb the very thing being measured.
 */
extern int printf(const char *, ...);
static size_t osv_vdevio_bios;
static size_t osv_vdevio_bytes;
static size_t osv_vdevio_gt128k;
static size_t osv_vdevio_maxlen;
static hrtime_t osv_vdevio_last_report;
#define OSV_VDEVIO_REPORT_NS 10000000000LL

"""

# 1. declarations, immediately before vdev_disk_hold
anchor = "static void\nvdev_disk_hold(vdev_t *vd)"
assert src.count(anchor) == 1, "vdev_disk_hold anchor"
src = src.replace(anchor, DECLS.lstrip("\n") + anchor)

# 2. NONROTPROOF in vdev_disk_open, right after the nonrot assignment
nonrot = "\tvd->vdev_nonrot = OSV_VDEV_NONROT_DEFAULT ? B_TRUE : B_FALSE;\n"
assert src.count(nonrot) == 1, "nonrot assignment anchor"
# zfs_vdev_aggregation_limit* are `static uint_t` inside module/zfs/vdev_queue.c,
# so they are not linkable from here. Print the cap the non-rotating path selects
# as its compile-time constant (SPA_OLD_MAXBLOCKSIZE); the VDEVIO gt128k counter
# carries the actual runtime binding proof.
PROOF = nonrot + """
\t/*
\t * NONROTPROOF: prove the RESOLVED lever, not the patch's presence.
\t * agg_cap_nonrot_KB is the cap vdev_queue_aggregate() selects when
\t * vdev_nonrot is true (SPA_OLD_MAXBLOCKSIZE, 128 KiB); the rotating
\t * alternative is 1 MiB.  The aggregation tunables are static to
\t * module/zfs/vdev_queue.c and not exported, so this line proves the
\t * FLAG and the VDEVIO gt128k counter proves it is HONOURED.
\t */
\tprintf("NONROTPROOF nonrot=%d default=%d agg_cap_nonrot_KB=%llu "
\t    "agg_cap_rot_KB=1024 vdev=%s\\n",
\t    (int)vd->vdev_nonrot, (int)(OSV_VDEV_NONROT_DEFAULT),
\t    (unsigned long long)(SPA_OLD_MAXBLOCKSIZE >> 10),
\t    vd->vdev_path ? vd->vdev_path : "?");
"""
src = src.replace(nonrot, PROOF)

# 3. VDEVIO accounting at the bio submit site in vdev_disk_io_start
submit = """\tbio->bio_caller1 = zio;
\tbio->bio_done = vdev_disk_bio_done;
"""
assert src.count(submit) == 1, "bio submit anchor"
ACCT = submit + """
\t/*
\t * VDEVIO: prove vdev_nonrot is HONOURED, not merely set.  With a correct
\t * non-rotating vdev, vdev_queue_aggregate() cannot build a span above the
\t * 128 KiB SPA_OLD_MAXBLOCKSIZE cap, so gt128k must remain 0.  A nonzero
\t * gt128k alongside NONROTPROOF nonrot=1 is the exact failure a source
\t * grep cannot see.
\t */
\tosv_vdevio_bios++;
\tosv_vdevio_bytes += size;
\tif (size > SPA_OLD_MAXBLOCKSIZE)
\t\tosv_vdevio_gt128k++;
\tif (size > osv_vdevio_maxlen)
\t\tosv_vdevio_maxlen = size;
\t{
\t\thrtime_t now = gethrtime();
\t\tif (now - osv_vdevio_last_report > OSV_VDEVIO_REPORT_NS) {
\t\t\tosv_vdevio_last_report = now;
\t\t\tprintf("VDEVIO bios=%llu bytes_MB=%llu gt128k=%llu "
\t\t\t    "maxlen_KB=%llu\\n",
\t\t\t    (unsigned long long)osv_vdevio_bios,
\t\t\t    (unsigned long long)(osv_vdevio_bytes >> 20),
\t\t\t    (unsigned long long)osv_vdevio_gt128k,
\t\t\t    (unsigned long long)(osv_vdevio_maxlen >> 10));
\t\t}
\t}
"""
src = src.replace(submit, ACCT)

open(F, "w").write(src)
print("INSERTED_OK")
print("nonrotproof:", src.count("NONROTPROOF"))
print("vdevio:", src.count("VDEVIO bios"))
