# Benchmark campaign: production-shaped OSv/PG vs Linux/PG on ZFS

> **CORRECTION 2026-09-08: the `zfs-2.4.1-osv` banner does NOT exist.** I propagated this as a
> runtime verification step and it is wrong. `grep -rl "zfs-2.4.1-osv"` across all C/C++ sources
> returns **nothing**. What the guest actually prints is `ZFS: OpenZFS 5000 initialized`, where
> `5000` is `SPA_VERSION_STRING` (`bsd/sys/cddl/.../sys/fs/zfs.h:367`) - the **pool format
> version**, identical for bsd_zfs and OpenZFS, and never a package version. So that line proves
> nothing about which implementation is loaded.
>
> **The reliable proofs that OpenZFS (not legacy bsd_zfs) is in the image are build-time:**
> (a) `modules/open_zfs/openzfs` objects compiled (282 in one measured build) versus **0**
> `bsd/.../fs/zfs/spa.c` objects; and (b) the four OpenZFS-only userspace libs shipped
> (`libzfs_core`, `libzutil`, `libshare`, `libtpool`), which `modules/zfs-tools/module.py` adds
> **only** under `conf_zfs=openzfs`. The vendored submodule is `6330a45b0` (META 2.4.2), not 2.4.1.



Started 2026-09-07. Requirements set by the user and non-negotiable across every arm:

- **No tmpfs, no /tmp for data.** PGDATA and WAL on ZFS on local NVMe. Verified per arm.
- **fsync=on, synchronous_commit=on.** Never disabled.
- **autovacuum=on.** Production default.
- **External load generation** from a separate driver instance over the private network.
- **Statistically valid: >=3 repeats per cell**, report median + min/max, flag >15% spread.
- Production-shaped config, dataset larger than shared_buffers so it is not an
  in-memory test.

## Capacity constraint (the reason this is phased, not parallel)

Standard on-demand vCPU quota is **192**, and Graviton counts against the SAME pool.
At campaign start 144 were in use (96 = my own in-flight maint7 build box; 48 = other
projects: libumem-arm-lo, pgtv-graphscale, solnix-dixi, which are not mine to touch).
Spot is only 32. So `m5d.metal` (96) and `c7gd.metal` (64) both failed to fit.

**Quota increase filed:** request `5b30ada283b94f24b7007cfe9c8f6f77HkWp1YuF`,
Standard on-demand 192 -> **512**, status PENDING. Approval is asynchronous.

## Arms, in launch order as capacity frees

| # | Arm | Instances | vCPU | Status |
|---|-----|-----------|------|--------|
| 1 | **Linux/PG baseline** (comparison target) | m5d.4xlarge DB + c5.4xlarge driver | 32 | RUNNING (agent 974ed15b) |
| 2 | **OSv/PG x86_64 bare metal** | m5d.metal + driver | 112 | waits for maint7 box to release |
| 3 | **OSv/PG x86_64 Firecracker** | m5d.metal + driver | 112 | after arm 2, or parallel if quota lands |
| 4 | **OSv/PG aarch64** | c7gd.metal + arm driver | 80 | after quota increase |

Arm 1 deliberately uses a 16-vCPU DB box so it fits the free 48 vCPU today rather than
idling until capacity frees. Note in analysis: arm 1's DB has 16 vCPU vs arm 2/3's
bare-metal guests, so cross-arm comparison must be per-vCPU or explicitly caveated -
do NOT compare arm 1 NOPM directly against a 32-vCPU OSv guest without saying so.

## Matched configuration across all arms

ZFS pool (identical properties, stated in every report):
    ashift=12 compression=off atime=off recordsize=8k
    sync=standard logbias=latency primarycache=all

PostgreSQL (scaled to each box's RAM, otherwise identical):
    max_connections=400
    shared_buffers = ~25% RAM
    effective_cache_size = ~50% RAM
    autovacuum=on autovacuum_naptime=15s
    fsync=on synchronous_commit=on wal_sync_method=fdatasync
    max_wal_size=16GB min_wal_size=2GB
    checkpoint_timeout=15min checkpoint_completion_target=0.9
    log_checkpoints=on log_min_duration_statement=1000
    max_files_per_process=200

Workload: HammerDB 6.0 TPROC-C, 200 warehouses (~20 GB, exceeds shared_buffers on
purpose), rampup 2 min + duration 5 min, `pg_timeprofile true`, xtprof log rotated
per run. Sweep VU 8/16/32/64/96, 3 repeats each.

## Mandatory second instrument: the independent connect probe

Separately from HammerDB, once per second for the whole timed window, from the driver:
open a FRESH connection, `select 1`, close. Report n, median, p95, p99, max and counts
>=1s, >=5s, >=10s.

Rationale: HammerDB's own percentiles hid a 19-second stall on the OSv side entirely.
The probe is what exposed it, and it measures the connect+fork+auth path - which on OSv
is where the remaining tail latency lives (fork was measured at ~65-150 ms each,
serialized). Every arm must report it so the OSv-vs-Linux fork-path gap is quantified
rather than inferred.

## Which OSv base, and why it must be stated

The OSv arms must use **`wip/pg-v26-faultfix`** (or later, with the fork clone-scan fix
folded in if it has landed by then). Rationale and caveat, both to be stated in every
OSv report:
- it carries all three landed tail-latency fixes: `ae077860c` (virtio-blk completion
  deadlock), `dad77b7f`+`746e5bcd` (fault-side AS-wide vmas_mutex);
- it is ~24 commits behind upstream/master. Benchmarking a stale base is what produced
  two phantom bugs and one invalidated p99 conclusion earlier in this project, so the
  base SHA must appear in the report and no number may be compared across bases.
- master-based alternatives were tested and rejected: master has no `fork()` at all, and
  master + #1456 aborts at PG's first fork (`fork+90` mmap fault) because it lacks the
  coherence stack. See CLEAN-BASE-CORRECTION.md.

## Known expectations, so results are not misread

- The OSv p99 gate (0 connect-probe samples >=5s at VU32) is expected to still FAIL:
  fork costs ~65 ms even after the scan fix, and 32 concurrent connects is ~2.1 s
  minimum. Report it as the residual fork floor, NOT as a regression.
- Established-session latency on OSv is now good (1.9 ms median, 0 samples >=5s) - the
  guest-global freeze is fixed. The gap is specifically the connect/fork path.
- Firecracker previously peaked at 145k NOPM @ VU16 (2.9x the old Linux VU8 baseline)
  but exposed two crashes not seen on QEMU/KVM; both have fixes in the base now.

## ATTRIBUTION IN DOUBT: the boot hang may be `-M q35`, not qemu 11

**Superseding note added later the same day.** Agent 0d31376d ran the experiment I should
have demanded the first time: a 4-way matrix on the SAME container qemu 8.1.3, same
kernel, same image.

    -M q35 + KVM  -> HANGS at "virtio-blk: Add blk device instances 0 as vblk0"
    -M q35 , TCG  -> HANGS at the identical line
    -M pc  + KVM  -> BOOTS, ZFS banner, clean poweroff
    -M pc  , TCG  -> BOOTS, ZFS banner, clean poweroff

The failure follows the **machine type**, not the accelerator and not the qemu build. The
earlier agent's hang ("vga: Add VGA device instance") is one console line earlier, so it
is plausibly the same q35 bug misattributed to the qemu version.

What I verified: `scripts/run.py` hardcodes `-machine q35` ONLY in the `--sata` branch
(line 165); a normal x86 virtio-blk run passes no `-machine` and gets qemu's default
(`pc`). So q35 came from the invocation, not run.py's default. That sharpens rather than
weakens the finding: **OSv hangs under `-M q35` at virtio-blk init, on both KVM and TCG,
and q35 is mentioned nowhere in documentation/ or scripts/.**

**ANSWERED, and it reconciles both facts into ONE root cause.** Host qemu 11.0.0 with
`-M pc` fails outright: `unsupported machine type: "pc"`. `-machine help` on
qemu-11.0.0-1.amzn2023 lists ONLY q35 variants (pc-q35-9.2 ... pc-q35-6.1); there is no
pc-i440fx at any version, because AL2023 built qemu 11 with the i440fx machine type
compiled out (pc-i440fx-9.2 and -8.2 both rejected).

So:
1. Host qemu 11 on AL2023 genuinely cannot boot OSv - the observation stands.
2. The CAUSE is not "qemu 11 is too new". The cause is that **OSv hangs at virtio-blk
   init under q35**, and AL2023's qemu 11 offers nothing but q35. One bug, two symptoms.
3. The fedora:39 container is still REQUIRED on this host, but for a newly-understood
   reason: its qemu 8.1.3 still ships the i440fx `pc` machine. **It is machine-type
   availability that matters, not the qemu version.** A qemu 11 built WITH i440fx would
   very likely boot OSv fine.
This also explains the earlier agent's hang one line earlier: q35, forced, no alternative.

**The actionable OSv bug, stated correctly:** OSv x86 does not boot under `-M q35`
(hangs at virtio-blk init, KVM and TCG alike). This matters increasingly because distros
are dropping i440fx - which raises its priority rather than lowering it.

(qemu 11 separately removed `-netdev user`/slirp. Still a real and distinct fact, kept
apart deliberately.)

**Nothing filed upstream pending that answer.** A q35 virtio-blk hang on stock qemu would
be a genuine upstream issue, but attribution is exactly what is in flux, and this project
nearly filed a wrong bug once before.

## SUBSTRATE CONSTRAINT discovered mid-campaign (2026-09-07) [ATTRIBUTION SUPERSEDED, SEE ABOVE]

**QEMU 11.0.0 on AL2023 cannot boot OSv at all.** Agent 342ad151 proved it
environmental with a 3-way A/B, all hanging identically right after
"vga: Add VGA device instance" and never reaching init:
  1. its patched tree
  2. UNPATCHED wip/fork-stage2-pr (clean clone, empty git diff)
  3. PRISTINE upstream/master 0e34e4dc2 (clean clone of cloudius-systems/osv)
Invariant across -cpu host / qemu64, smp 1 / 4, KVM on/off, virtio-rng on/off, and a
5-minute wait. qemu-11.0.0-1.amzn2023 + SeaBIOS 1.17.

**Consequence for this campaign: every OSv arm must boot the guest from inside the
fedora:39 container (qemu 8.1.3) via `-kernel loader.elf`, never with the AL2023 host
qemu.** Prior runs in this project used exactly that path successfully. This is now a
standing constraint in every OSv agent brief, alongside the already-known items:
  - host qemu hangs at "random: device unblocked" in some configurations
  - the qcow2/MBR boot path triple-faults; `-kernel loader.elf` works
  - the guest blocks forever on DHCP, so boot with a static
    `--ip=eth0,...  --defaultgw=...`
  - AL2023 has no bridge-utils; build br0/tap0 with iproute
  - QEMU 11 also removed `-netdev user` (slirp), so scripts/run.py default networking
    fails; only `--nics 0` works with it

Asked for the decisive confirmation ("container qemu 8.1.3 boots the same image that
host qemu 11.0.0 hangs on") so this is documented as a known-good path rather than
folklore, plus whether it is SeaBIOS-specific or broader. If it reproduces on upstream
master it deserves an upstream issue - OSv will hit this as distros move to qemu 11 -
but the text gets reviewed before filing, since this project nearly filed a wrong
upstream bug once already.

## Third bootfs bug found (distinct from the other two)

`usr_ramfs.manifest.skel` lists `/tools/mount-fs.so: tools/mount/mount-fs.so` and
`/tools/umount.so: tools/mount/umount.so`, but the Makefile adds `$(tools)` to
`bootfs_dep` only for `fs=ext` and `fs=zfs`, never ramfs. So a FRESH clone building
`fs=ramfs` fails 100% at MKBOOTFS with FileNotFoundError on
`tools/mount/mount-fs.so`. Verified by me on pristine upstream/master.

That makes three independent bootfs/module defects now identified:
  1. #1494 - bootfs_dep misses the ZFS library/tools for non-zfs roots (PR open)
  2. Bug A - `provides=['zfs']` shadows modules/zfs/module.py, dropping its manifest
     line (no PR yet; deferred pending a non-invasive fix)
  3. this one - bootfs_dep misses `$(tools)` for ramfs (PR being opened)
All three explain build failures this project has been working around by hand for
months.

## Capacity unblocked, campaign now parallel (2026-09-07, later)

Two breaks at once:
- **Quota increase APPROVED: 192 -> 512** vCPU (request 5b30ada...HkWp1YuF).
- maint7's build box terminated, returning 96 vCPU.
Usage at relaunch was 128 of 512, so ~384 free. All arms launched in PARALLEL rather
than serially as originally planned.

### Live agents
| Agent | Arm | Boxes |
|---|---|---|
| 974ed15b | Linux/PG baseline on ZFS | m5d.4xlarge DB + c5.4xlarge driver |
| 0d31376d | OSv x86_64: QEMU-KVM **and** Firecracker | m5d.metal + shared driver |
| ff3a9ff1 | OSv aarch64 Graviton3 | c7gd.metal (+own driver if contended) |
| 97dc21c0 | Non-benchmark open issues (no EC2) | - |

Guest geometry standardised at **32 vCPU / 64 GB** for both OSv arms so x86-vs-aarch64
is a genuine cross-ISA comparison, and both are comparable per-vCPU to the 16-vCPU
Linux arm (with the caveat stated, not glossed).

### The container-qemu constraint was baked into both OSv briefs before launch
Rather than being discovered mid-run. Each brief carries the full footgun list: no host
qemu 11, `-kernel loader.elf` not qcow2/MBR, static IP not DHCP, iproute not
bridge-utils, `dnf --skip-broken`, `image=zfs,zfs-tools,postgres18-musl` without an
explicit `open_zfs`, and the 512-byte-logical/ashift=12 pool invariant. Every one of
those cost a previous run.

### Expectations pre-recorded so results cannot be misread
- The connect-probe p99 gate is expected to STILL FAIL at VU32 (fork ~65-150 ms x 32
  concurrent implies a multi-second floor). That is residual fork cost, not a
  regression. Established-session latency should be ~1.9 ms median.
- aarch64 crashed at VU128 previously; agents are told to RE-TEST before investigating,
  since it may predate `ae077860c`. A reproducible crash is a valid result.
- Prior x86 finding to confirm or refute: both stacks I/O-bound on WAL writes before
  vCPU-bound, ZFS COW capping ~500-530 MB/s vs ext4 ~766 MB/s.

## Two more PRs opened by maint7 (now 45 open, 28 merged)
- **#1496** build: order the mount tools before bootfs for fs=ramfs (the third bootfs bug)
- **#1497** zfs: let each ZFS provider carry the libsolaris.so manifest entry (Bug A,
  the `provides=['zfs']` module shadowing, previously deferred)
Both are being independently re-verified against pristine upstream by agent 97dc21c0,
including by executing the module resolver for #1497. Disagreement is an acceptable
outcome; I would rather catch a wrong PR before the maintainer does.

## BRIEF DEFECT caught mid-run: `image=zfs` silently selects LEGACY BSD ZFS

Found by agent ff3a9ff1 on the aarch64 box before measuring; verified by me. This would
have voided BOTH OSv arms silently.

`modules/zfs/module.py` line 9:

    if os.environ.get('conf_zfs', 'bsd') == 'openzfs': api.require('open_zfs')
    else:                                             api.require('bsd_zfs')

So `image=zfs,zfs-tools,postgres18-musl` **without `conf_zfs=openzfs` builds the legacy
BSD ZFS**, not OpenZFS. My briefs specified the image line but omitted the flag.

Consequences, all confirmed on the box:
- legacy bsd_zfs rejects the property: `property 'ashift' is not a valid pool property`
- it has no settable ashift at all. `bsd/.../fs/zfs/vdev_disk.c:91`:
      *ashift = highbit(MAX(DEV_BSIZE, SPA_MINBLOCKSIZE)) - 1;
  i.e. derived from DEV_BSIZE=512, so **ashift=9 always**
- therefore every ZFS property in my brief (ashift, recordsize, logbias, primarycache)
  either errored or silently did not apply

The agent correctly identified my "512-byte logical disk + ashift=12" invariant as
self-contradictory *on bsd_zfs*, and proposed accepting ashift=9 to stay identical to the
x86 arm. **I overrode that**: the tuning doc shows every historical run passed
`conf_zfs=openzfs` explicitly (doc lines 58/75/78, "conf_fork=1 and conf_zfs=openzfs
(OpenZFS, not the legacy bsd ZFS) are the key knobs"), and the north star is
OpenZFS-on-NVMe. With OpenZFS the property IS accepted, so 512B logical geometry +
explicit `ashift=12` is satisfiable after all - the contradiction existed only because
bsd_zfs cannot honour it.

Resolution: both arms rebuild with `conf_fork=1 conf_zfs=openzfs`, keep
`image=zfs,zfs-tools,postgres18-musl` (placeholder resolves to open_zfs; still no
explicit `open_zfs`, which is #1497's shadowing bug), keep the 512B disk, set
`-o ashift=12`. **Both must now PROVE the implementation**: `zpool get ashift`,
`zdb -C | grep ashift`, and evidence of which module is loaded. "It said ZFS" is
insufficient - that ambiguity is precisely what let the error hide.

Fourth instance of the project's signature failure mode: a silent default that still
stamps success (ext_fsync==vop_nullop; swallowed git apply; ramfs PGDATA; now bsd_zfs
masquerading as ZFS).

## Canonical aarch64 boot recipe (corrected)

- **`-kernel loader.elf` does NOT boot on aarch64**: dies at `premain: failed to get TLS
  data from ELF`. **`-kernel loader.img` boots** (OSv v0.57.0-510-g8711aeed, 32 vCPU,
  153 ms). My `-kernel loader.elf` guidance was x86-derived and wrongly stated as
  cross-ISA.
- The built root disk is **qcow2, not raw**. Forcing `format=raw` produces "Cannot find
  the pool label", which mimics pool corruption but is a format mismatch. Do not let it
  cast doubt on a healthy pool.
Both to be recorded verbatim in the tuning doc so they are not rediscovered painfully.

## x86 arm: OpenZFS confirmed at RUNTIME (the proof I demanded)

Guest console prints `zfs-2.4.1-osv` / `zfs-kmod-zfs-2.4.1-osv` = **OpenZFS 2.4.1**.
bsd_zfs emits no such banner. Corroborated at build time by 282 open_zfs objects and
**0** bsd `spa.c` objects. So this arm is genuinely OpenZFS, not the legacy
implementation - the ambiguity that nearly voided both arms is closed for x86.

Note the version is **2.4.1**, while #1488 (OpenZFS 2.4.3->2.4.4) is in flight. The
measured ZFS version is therefore part of the result identity, alongside the
(osv SHA, apps SHA) pair. Report triple: (osv SHA, apps SHA, zfs banner).

## cpiod.so is absent from normal images BY DESIGN (not a packaging bug)

The x86 arm's seed-push failed with "Failed to load object" for `/tools/cpiod.so`.
Investigated rather than patched:
- `Makefile:466` puts `tools/cpiod/cpiod.so` in `$(tools)`, so it IS built for zfs/ext
- but the ONLY manifest that packages it is **`zfs_builder_bootfs.manifest.skel`**, the
  dedicated image-builder appliance. No `usr*.manifest.skel` and no module ships it.
So a normal `image=zfs,zfs-tools,postgres18-musl` guest legitimately has no cpiod, and
the error is expected rather than a defect in the build.

Directed the arm to **drop the seed-push entirely** and instead let HammerDB's
`buildschema` create the database over the network from the driver, with only an
initialised running PostgreSQL on the ZFS dataset required beforehand. That needs no
host-to-guest transfer, and it is the more production-shaped path anyway: the database is
built by the client, on ZFS, with fsync on. Explicitly rejected adding cpiod to the
manifest, since that would change the image under test.

## MY BRIEFING ERROR: the aarch64 arm was pointed at a base missing three fixes

Agent ff3a9ff1 hit two reproducible guest failures at **VU8**, far below the expected
VU128 boundary. Cause is almost certainly base staleness, which I introduced by naming
`wip/aarch64-forkcow-signed` without checking what it contains.

    ae077860c  virtio-blk completion deadlock        MISSING
    dad77b7f   fault-side AS-wide vmas_mutex fix     MISSING
    746e5bcd   fault-side AS lock companion fix      MISSING
    772a8f2c4  callout use-after-free                present

`ae077860c` took a worst-case stall from 19,327 ms to 7,782 ms on x86 and was diagnosed
as a **virtio completion-path deadlock**. The agent's symptom 2 matches that shape
exactly: guest alive internally (PG still logging autovacuum every 15 s) while the
network stops answering ARP and TCP, a static ARP entry does not help, and tap0 shows
14.8 GB TX vs 155 MB RX. I asked it to benchmark a branch predating the fix for the
failure it then hit.

### The agent's RX suspicion, cleared with evidence
It flagged `b318d8502` "virtio-net: experimental inline RX delivery (OSV_RX_INLINE)" as a
prime suspect. Checked: `drivers/virtio-net.cc:74` documents it **off by default** and
`rx_inline_weight()` (:88-91) only enables it when the env var is set non-zero. So the
commit is inert unless exported. A reasonable suspicion, killed cheaply by reading the
default rather than by running an experiment.

### Crash #1 is worth keeping separate
`page fault outside application, addr: 0x00001000010bf000`, PC at
`elf::object::dynamic_tag(unsigned int)+8`, backtrace
`mmu::vm_fault -> page_fault -> elf::object::lookup_symbol_deep -> dlsym`, with registers
holding `/plpgsql.so` path bytes, i.e. faulting in the ELF dynamic-symbol path while a
NEW BACKEND dlopens plpgsql. That is the fork+dlopen path, squarely in the fork/COW
stack's territory. Instruction: re-test after the three fixes. If it SURVIVES it is a
real aarch64 fork/dlopen bug and gets fully characterised; if it disappears, say so.

### Unplanned durability proof, banked
`zpool import` persists the dataset across reboots and PG performed genuine WAL crash
recovery after the VU8 crash: **"redo done at 6/5D663EA0", 67.9 s**, recovering the full
200-warehouse dataset. fsync and the ZIL did their job through a real crash on aarch64.
That partially answers the **P5 durability** question, which nothing had measured yet -
obtained accidentally, from a crash, which is why crashes get reported rather than hidden.

Also retained: 200 wh / 6M customers / 20M stock / 60M order_lines / 19 GB built and
verified on OpenZFS-on-NVMe, ashift=12 confirmed, all mandated GUCs live.

### Fourth instance of the stale-base pattern, second one I caused
My own STALENESS-PATTERN.md says "before concluding X is broken, verify the base contains
the relevant upstream fix." I did not apply it when writing the brief. The check is one
line and I have now paid for skipping it twice:

    git merge-base --is-ancestor <fix> <branch>

**Standing rule going forward: every benchmark brief must list the fixes the base is
required to contain, verified with merge-base, before the box is launched.**
