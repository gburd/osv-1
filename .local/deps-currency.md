# External dependency currency -- 2026-09-11 (maintenance sweep, round 13)

Re-verified 2026-09-11 by `git ls-remote` / the GitHub API against each real
upstream, not from cached notes. **Every pin below is unchanged from round 12
and no bump is warranted.** Nothing was bumped.

Upstream OSv master: **0e34e4dc2**, still UNMOVED since 2026-08-17.

## Round 13 re-verification (2026-09-11), pasted evidence

    OpenZFS  71a9f9578616a90c3c14bb59629fb4d31bfd68d1  refs/tags/zfs-2.4.4^{}   <- PR #1488 pin
             83020cf8259d057d4cc9102010c05f07ffdfc136  refs/tags/zfs-2.4.3^{}   <- upstream/master
             full 2.4.x tag list from openzfs/zfs: 2.4.0 2.4.1 2.4.2 2.4.3 2.4.4 2.4.99
             newest stable = zfs-2.4.4.  NO zfs-2.4.5 on any ref.  2.4.99 is a dev tag.
    lwext4   osvunikernel/lwext4 HEAD = refs/heads/master = 6f6d8f7c509da696e71e80cc5a59abfc48e4971b
             == #1500's pin exactly (identical); real gkostka/lwext4 HEAD = 58bcf89a1
    musl_1.2.1  73cc775bee53300c7cf759f37580220b18ac13d3  refs/tags/v1.2.1   (exact tag, deliberate)
                real musl latest = v1.2.6
    musl_0.9.12 372a948b8139c6583045b2cd91b6b91fcb2e5881  refs/tags/v0.9.12  (exact tag, deliberate)
                that fork's master has moved on to 00733dd1c
    acpica   cloudius fork HEAD = refs/heads/master = 3e45e0f2383cabdc00275c00a12ea8797f285c30 == pin
             real acpica/acpica newest release tag = R2025_04_04
    kbuild   osvunikernel/kbuild-standalone HEAD = 9f1d27a86879d1fa0944f426f5fa20c6be8de9da == pin
    apps     cloudius-systems/osv-apps HEAD = b2d53b348c15ee1c1a05b1f23fe4f4702dc9cbef == master's gitlink

So: OpenZFS 2.4.4 remains newest stable (no delta, and therefore no
patch-conflict question to answer); lwext4 / acpica / kbuild / apps are all
exactly at their upstream tips; both musl pins remain deliberate release-tag
pins rather than drift.

### Submodule reachability, checked the authoritative way

A local `git -C <path> cat-file -e` **false-positives** on shallow submodules,
so reachability was checked by asking the remote to serve the commit:

    5cb19033555d6d4370da905965016f0adb81e515  local=YES  remote REACHABLE (gburd + cloudius)
    b38b99cd9302af01fb388e569bc0911c0e90bbc4  local=YES  remote REACHABLE (gburd + cloudius)
    57c607984393901ce556a75f81ea40f7c469d1f3  local=NO   remote UNREACHABLE:
        fatal: remote error: upload-pack: not our ref 57c607984393901ce556a75f81ea40f7c4

The repinned branches `gh-fork/wip/forkroot-arm-base-repinned` and
`gh-fork/integ/pg-fork-zfs-repinned` both record `apps` = **5cb1903**, and both
are **strict fast-forwards** of their unpinned predecessors carrying exactly one
signed commit (`c7bb278bf` / `d3e9e973d`). The dangling `57c6079` pin still
appears on **101** refs in this repo.


## Pins

| dep | how pinned | current pin | upstream latest | update warranted? |
|---|---|---|---|---|
| **OpenZFS** (modules/open_zfs/openzfs) | submodule -> github.com/openzfs/zfs | `upstream/master`: **83020cf82 = zfs-2.4.3**; **PR #1488: 71a9f9578 = zfs-2.4.4** | **zfs-2.4.4** (2026-08-21). No 2.4.5 exists on any ref. `zfs-2.4.99` is a dev tag (not a release, dated 2025-08-22) | **No. 2.4.4 is newest stable and #1488 is already exactly on it.** Verified the patch series applies to a real 2.4.4 checkout, see below. |
| **lwext4** (modules/lwext4) | build-time clone of osvunikernel/lwext4; **now pinned by PR #1500** | #1500 pins `6f6d8f7c` | osvunikernel fork HEAD = **6f6d8f7c (identical)**; real upstream gkostka/lwext4 HEAD 58bcf89a, last push **2024-03-22** | No. #1500's pin equals the current fork tip, so merging it changes no bits and removes the moving-tip hazard. |
| **musl_1.2.1** | submodule -> osvunikernel/musl | `73cc775b` = **tag `v1.2.1` exactly** | fork master a5aff1972 (moved past the tag); real musl **v1.2.6** | Not this pass. Pin is a deliberate release tag, not a drifted commit. 1.2.2-1.2.6 exist; bumping is a fork-rebase project. Backlog. |
| **musl_0.9.12** | submodule -> cloudius-systems/musl | `372a948b` = **tag `v0.9.12` exactly** | that fork's HEAD 00733dd1 = tag `v1.1.4` | No. Legacy path, deliberate tag pin. |
| **acpica** (external/x64/acpica) | submodule -> cloudius-systems/acpica | `3e45e0f2` (fork HEAD, **dated 2013-01-24**) | real upstream acpica/acpica HEAD 57a2afa78 (2026-09-04), newest tag R2025_04_04 | No, but note the size of the gap: the OSv fork is ~13 years behind real ACPICA. Deliberate historical fork, not a drift. Out of scope for a currency sweep; flagging it as a fact, not proposing a bump. |
| **kbuild** | submodule -> osvunikernel/kbuild-standalone | `9f1d27a8` | fork HEAD == `9f1d27a8` (identical) | No. At fork tip. |
| **apps** | submodule -> cloudius-systems/osv-apps | `b2d53b348` | remote HEAD == `b2d53b348` (identical), commit resolves ("fio: switch to github", 2026-08-02) | No. **The dangling-pin problem noted in earlier sweeps is resolved**: the pinned commit now exists at the remote. Prior x86 provenance concerns tied to that dangling pin are historical. |
| swagger-ui / osv-gui | submodules | 5d7010b96 / c93b2f5cf | fork HEADs identical | No. Dormant, not on any active PR path. |

## Upstream-filed work: four items, three open and one MERGED

Re-checked 2026-09-11 against the API.

| item | actual state | note |
|---|---|---|
| **gkostka/lwext4 #100** | **OPEN, and it is an ISSUE, not a pull request** | `repos/gkostka/lwext4/pulls/100` returns HTTP 404; `issues/100` resolves with `"pr": false`. Filed 2026-07-14, **0 comments**, `updated_at` == `created_at` == `2026-07-14T14:24:21Z` (unchanged since filing, now across four checks). That upstream's last push was **2024-03-22**. **No reply is expected and none is owed to us.** State this plainly rather than implying pending review; the silence is a dormant upstream, not a queue position. |
| **osv-apps #73** | OPEN, DRAFT, head `5cb1903` | Updated 2026-09-09. Carries the shadowed-build fix plus the corrected `io_method` note. 1 comment. |
| **osv-apps #71** | OPEN, 0 comments, 0 review comments | `ec2-audit` app, filed 2026-07-02, `updated_at` == `created_at`. No action available to us. |
| **osv-apps #72** | **CLOSED because it was MERGED** (`"merged": true`, `merged_at` 2026-07-05T15:02:29Z) | `io-uring-bench`. A completed upstream contribution, not outstanding work. |

A repo-wide `author:gburd` search for open items confirms **gkostka/lwext4#100 is
the only OSv-related item filed outside cloudius-systems/osv** that is still
open; everything else returned by that search belongs to unrelated projects.


### osv-apps #73 verification (the `5cb1903` update)

The fix is real and the mechanism checks out by reading the tree, not the prose:

    postgres18-musl/Makefile:  -.PHONY: module
                               +.PHONY: module build
    postgres18-musl/build.sh:18   BUILD="$HERE/build"     <- creates a real ./build directory

`module: build` depends on a target named `build` while the recipe creates a
directory of the same name, so without `build` being phony make considers the
target up to date and **skips `./build.sh` entirely**, producing an image with no
PostgreSQL while exiting 0. Declaring it phony is the correct minimal fix. The
`io_method` comment change is also accurate: it stops conflating `worker` (shared
memory + LWLock + latch + forked IO workers, no kernel AIO needed) with
`io_uring` (genuinely incomplete, additionally needs `--with-liburing`), and
correctly notes `io_method` is `PGC_POSTMASTER` so one build can select any
method at run time.

## OpenZFS version reconciliation: no discrepancy exists

The brief asked which of "submodule `6330a45b0`" and "META reports 2.4.2" is
authoritative. **They agree, and both were describing this worktree's branch,
not master.** Three things carry a version and all three are consistent:

| ref | gitlink (what builds) | `.gitmodules branch=` (advisory) | META at that commit |
|---|---|---|---|
| this worktree (`wip/pg-rx-directwake`) | `6330a45b0` | `zfs-2.4.2` | **2.4.2** |
| `upstream/master` | `83020cf82` | `zfs-2.4.3` | **2.4.3** |
| PR #1488 (`cb23ebdf3`) | `71a9f9578` | `zfs-2.4.4` | **2.4.4** |

The **gitlink is authoritative** (it is the commit git checks out). `.gitmodules
branch=` is advisory, only consulted by `git submodule update --remote`. META is
a file inside the pinned commit and therefore always agrees with the gitlink by
construction. Each gitlink dereferences to exactly its release tag (verified
against openzfs/zfs: `6330a45b0` = "Tag zfs-2.4.2", `83020cf82` = 2.4.3,
`71a9f9578` = 2.4.4). So "we ship 2.4.4 but the submodule says 2.4.2" was
comparing #1488's pin against a stale local branch's pin. Nothing to reconcile.

One real nit: Makefile:53-54 has a hardcoded comment saying the submodule is
"pinned to ... zfs-2.4.2", which is stale on master (now 2.4.3) and on #1488
(2.4.4). Cosmetic, comment-only, and it will be wrong again after the next bump;
worth deleting the version from the comment rather than updating it.

## The "~29 patches" premise was wrong: master carries ONE

The brief refers to "our ~29 patches in `modules/open_zfs/patches/`". That is
true of **this worktree's branch only** and is the pre-#1423 mechanism:

| ref | tracked `.patch` files | tracked files under `modules/open_zfs/osv/` |
|---|---|---|
| this worktree (`wip/pg-rx-directwake`) | **29** | 0 |
| `upstream/master` | **1** | **117** |
| PR #1488 | **1** | **117** |

Master replaced the 29-patch series with 117 tracked platform-layer source files
under `modules/open_zfs/osv/` plus a single
`0001-osv-openzfs-upstream-file-edits.patch` for the edits that must land in
upstream OpenZFS files. The 29 files in my worktree are the older mechanism
carried by this branch.

**Conflict question, answered by execution, not inspection.** Fetched a real
`zfs-2.4.4` checkout (`71a9f9578`, `META` Version 2.4.4) and ran the actual
patch:

```
$ git apply --check --whitespace=nowarn 0001-osv-openzfs-upstream-file-edits.patch
$ echo $?
0
```

- master's patch and #1488's patch are **byte-identical**, and that one patch
  applies cleanly to 2.4.4 (exit 0).
- **The check has teeth:** corrupting a single context line in that patch makes
  it fail (`error: include/sys/zfs_file.h: patch does not apply`, exit 1). So
  exit 0 above is a real result, not a vacuous one.
- The 29 old patches do **not** apply to a bare 2.4.4 tree (25 of 29 fail with
  `module/os/osv/zfs/...: No such file or directory`) because they patch files
  that only exist once the platform layer is in place. That is expected for a
  superseded mechanism and is **not** a 2.4.4 incompatibility.

**So: no bump is needed, and nothing was bumped.** #1488 is already on the
newest stable OpenZFS and its patch applies to it.

## Upstream-filed work against OTHER projects (verified 2026-09-09)

Per-repo `author:gburd` search. The prior sweeps' claim that **exactly one**
thing was ever filed outside cloudius-systems/osv is **wrong** -- there are
**four**, in two repos:

- **gkostka/lwext4#100** -- "Out-of-bounds read: ext4_ext_check() does not bound
  eh_max/eh_entries to block capacity". **Nothing has moved.** Still `open`,
  still **0 comments**, `updated_at` still `2026-07-14T14:24:21Z`, identical to
  the last two checks. That upstream's last push was **2024-03-22**, so no reply
  is expected. Stating it plainly: there is no activity, and no reason to expect
  any. Non-blocking; our fix ships in the osvunikernel fork OSv builds from and
  is also OSv PR #1449.
- **cloudius-systems/osv-apps#73** -- postgres18-musl demo, OPEN, draft, held on
  the OSv fork/COW landing. 1 comment, posted **today** by a concurrently
  running agent (two one-line Makefile/comment fixes). Live, not stale.
- **cloudius-systems/osv-apps#71** -- ec2-audit app, OPEN, 0 comments since
  2026-07-02.
- **cloudius-systems/osv-apps#72** -- io-uring-bench, CLOSED.

Zero filed at: openzfs/zfs, qemu/qemu, osvunikernel/musl, osvunikernel/lwext4,
cloudius-systems/acpica, firecracker-microvm/firecracker (each verified
`total_count: 0`).

## Net

Nothing needs a dependency bump and nothing was bumped. Two standing latent
items, both backlog, neither blocking a PR:

1. musl 1.2.1 -> 1.2.x fork rebase (a deliberate project, not a sweep task).
2. lwext4's unpinned build-time clone -- **already fixed by PR #1500**, which
   pins the exact commit the fork currently sits at, so merging it is a no-op on
   bits and removes the reproducibility hazard.
