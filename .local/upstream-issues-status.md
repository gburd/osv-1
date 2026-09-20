# Upstream issues/PRs we filed -- status 2026-08-15 (re-verified 2026-08-17 sweep #2)

2026-08-17 sweep #2: lwext4 gkostka#100 re-checked = OPEN, 0 comments, updatedAt
still 2026-07-14T14:24:21Z (unchanged, no reply). Non-blocking (fix in the OSv
fork). Tracking issue cloudius-systems/osv#1474 (5 OpenZFS known-failing tests)
remains our own tracker; #1423 (the OpenZFS PR it documents) is now MERGED so the
gap-doc landed on master.

## lwext4: OOB read in ext4_ext_check (gkostka/lwext4 #100)
- URL: https://github.com/gkostka/lwext4/issues/100
- Author: gburd. Filed: 2026-07-14.
- Title: "Out-of-bounds read: ext4_ext_check() does not bound eh_max/eh_entries to block capacity"
- STATUS: **OPEN, 0 comments, no maintainer response.** (Re-checked 2026-08-16
  19:10Z: unchanged; gh reports state OPEN, comment_count 0, updatedAt still
  2026-07-14T14:24:21Z -- no reply since filed.)
- Context: this is the upstream report of the ext4 extent-header hardening that
  OSv carries locally (the sec-ext4-readlink / ext4 heap-overflow family, OSv
  PR #1449). It was filed against the *real* upstream (gkostka/lwext4), which is
  effectively dormant (last push 2024-03-22). No response expected; our fix lives
  in the osvunikernel/lwext4 fork that OSv actually builds from, so OSv is not
  blocked on an upstream merge. No action available -- leave open as the
  good-citizen upstream report.
- Note: the drafted `/tmp/lwext4-h7-issue.md` referenced in the task no longer
  exists on this host (a prior /tmp sweep cleaned it). Issue #100 is the filed
  form of that draft (the ext4 bounds bug), so "was it filed?" = YES, #100.

## OpenZFS
- No issue/PR filed by gburd against openzfs/zfs. The OpenZFS-on-OSv fixes
  (kstat ABI, taskq_wait, ZIL replay v_size, etc.) are OSv-platform-layer
  changes carried in modules/open_zfs/patches/, not upstream OpenZFS bugs, so
  there is nothing to file upstream. Confirmed: `gh search issues/prs
  --author gburd --repo openzfs/zfs` = none relevant.

## musl
- No issue/PR filed. The OSv musl fork (osvunikernel/musl @ 1.2.1) is where OSv
  patches land; no upstream musl.org report outstanding.

## Net
One filed upstream issue (lwext4 #100), still open + unanswered, but against a
dormant upstream and non-blocking (fix already in the OSv-built fork). Nothing
actionable -- no maintainer has responded and none is expected.
