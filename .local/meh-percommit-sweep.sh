#!/usr/bin/env bash
# Per-commit standalone build sweep for the osv-improvements feat/* stack.
# Fetches the rewritten branches from a local git bundle (so we validate the
# pre-push history), walks each feat/* tip oldest->newest, does a CLEAN build at
# each tip with the maximal target that tip supports, and records PASS/FAIL.
# This is the "git rebase --exec make" the OSv reviewer runs, made faithful by
# cleaning between tips (standalone build).
#
# Harness fixes baked in (learned the hard way 2026-06-07):
#  - git clean -xfd (SINGLE -f): one -f leaves nested submodule git repos intact;
#    double -ff descends into and wipes them, forcing a full re-clone every tip.
#  - Absolute github submodule URLs: early-tip .gitmodules use relative
#    ../../cloudius-systems/... which resolve against codeberg origin -> 404.
#  - git submodule update --init --force: repopulates submodule dirs left as a
#    bare gitlink (.git file, empty tree) by a previously-aborted init.
set -uo pipefail

BOOST=/nix/store/09yk6h7338qww8jzq2vf8vphffg8zxqh-boost-1.87.0-dev
SWEEP=/scratch/gburd/sweep
SRC=$SWEEP/osv
BUNDLE=/scratch/gburd/osv-rewrite-relocated.bundle
ZFS_URL=https://codeberg.org/gregburd/zfs.git
LOG=$SWEEP/sweep.log
RESULT=$SWEEP/RESULT.txt

# Tips in dependency order (oldest -> newest).
TIPS=(
  feat/build-nix
  feat/musl-1.2
  feat/mmu-shm
  feat/pagecache-vfs
  feat/trim-discard-multiq
  feat/io-uring
  feat/kernel-fixes
  feat/openzfs
  feat/crucible-block-device
  feat/apps-docs
)

mkdir -p "$SWEEP"
: > "$RESULT"
echo "=== sweep start $(date -Is) on $(hostname) nproc=$(nproc) ===" | tee "$LOG"

if [ ! -d "$SRC/.git" ]; then
  echo "ERROR: $SRC is not a git tree. Expected the manually-fixed sweep tree." | tee -a "$RESULT"
  exit 1
fi
cd "$SRC" || exit 1

# Pull the rewritten branches from the bundle into bundle/* refs.
echo "=== fetching rewritten branches from $BUNDLE ===" | tee -a "$LOG"
git fetch "$BUNDLE" '+refs/heads/*:refs/bundle/*' >>"$LOG" 2>&1 || {
  echo "BUNDLE FETCH FAILED" | tee -a "$RESULT"; exit 1; }

# Force absolute working submodule URLs (early tips use relative ../../ that 404).
set_urls() {
  git config -f .gitmodules submodule.external/x64/acpica.url https://github.com/cloudius-systems/acpica
  git config -f .gitmodules submodule.apps.url https://github.com/cloudius-systems/osv-apps
  git config -f .gitmodules submodule.modules/httpserver/swagger-ui.url https://github.com/cloudius-systems/swagger-ui.git
  git config -f .gitmodules submodule.modules/httpserver/osv-gui.url https://github.com/cloudius-systems/osv-gui.git
  if git ls-tree HEAD external/openzfs | grep -q commit; then
    git config -f .gitmodules submodule.external/openzfs.url "$ZFS_URL"
  fi
  git submodule sync >>"$tlog" 2>&1
}

for tip in "${TIPS[@]}"; do
  echo | tee -a "$LOG"
  echo "############################################################" | tee -a "$LOG"
  echo "### TIP $tip  $(date -Is)" | tee -a "$LOG"
  echo "############################################################" | tee -a "$LOG"
  tlog="$SWEEP/build-$(echo "$tip" | tr '/' '_').log"
  : > "$tlog"

  # Checkout the rewritten tip. SINGLE -f clean preserves submodule working trees.
  git checkout -f "bundle/$tip" >>"$LOG" 2>&1 || { echo "$tip: CHECKOUT_FAIL" | tee -a "$RESULT"; continue; }
  git reset --hard "bundle/$tip" >>"$LOG" 2>&1
  git clean -xfd >>"$LOG" 2>&1
  sha=$(git rev-parse --short HEAD)

  # Remove submodule working trees the CURRENT tip does not track. git clean's
  # single -f deliberately leaves nested git repos alone, so a leftover
  # external/openzfs tree from a later tip would make an early kernel-only tip
  # (build-nix) wrongly detect HAS_ZFS and build the wrong target. Drop any
  # external/openzfs tree unless this tip actually carries the gitlink.
  if ! git ls-tree HEAD external/openzfs | grep -q commit; then
    rm -rf external/openzfs 2>/dev/null || true
  fi

  set_urls
  # --force repopulates any submodule dir left as a bare gitlink by a prior abort.
  # The feat/musl-1.2 pin is now public v1.2.1 (73cc775b), fetchable straight
  # from the osvunikernel/musl v1.2.1 tag, so no local musl bundle is needed.
  git submodule update --init --recursive --force >>"$tlog" 2>&1

  # Detect target from the GIT TREE (authoritative), not leftover working-tree
  # dirs: a stale external/openzfs left by a later tip's checkout would falsely
  # flag an early kernel-only tip as a zfs build.
  # EVERY tip builds fs=zfs image=zfs-test, because that is the reviewer's
  # canonical build: bare `make` delegates to scripts/build which defaults
  # fs_type=zfs (upstream Makefile:25 + scripts/build:209). Early tips build
  # ZFS from the in-tree bsd/sys/cddl sources; openzfs+ from external/openzfs.
  # A bare kernel/loader `make` is NOT a real target and spuriously fails on
  # the unconditional libsolaris.so line in the (upstream-identical) bootfs
  # manifest. Crucible is layered on only where its profile exists.
  HAS_CRUCIBLE=0
  if git cat-file -e HEAD:conf/profiles/x64/crucible.mk 2>/dev/null; then HAS_CRUCIBLE=1; fi

  if [ "$HAS_CRUCIBLE" = 1 ]; then
    desc="zfs+crucible image"
    makeargs="conf_drivers_profile=crucible fs=zfs image=zfs-test boost_base=$BOOST"
  else
    desc="zfs image"
    makeargs="fs=zfs image=zfs-test boost_base=$BOOST"
  fi

  echo "### $tip ($sha) target=[$desc] HAS_CRUCIBLE=$HAS_CRUCIBLE" | tee -a "$LOG" "$tlog"
  echo "### make $makeargs" | tee -a "$tlog"

  t0=$(date +%s)
  nix-shell -p boost ncurses flex bison --run \
    "OSV_NO_JAVA_TESTS=1 make -j$(nproc) OSV_NO_JAVA_TESTS=1 $makeargs" >>"$tlog" 2>&1
  rc=$?
  t1=$(date +%s)
  dur=$((t1 - t0))

  if [ $rc -eq 0 ]; then
    echo "$tip ($sha): PASS [$desc] ${dur}s" | tee -a "$RESULT" "$LOG"
  else
    echo "$tip ($sha): FAIL rc=$rc [$desc] ${dur}s -- see $tlog" | tee -a "$RESULT" "$LOG"
    echo "    --- last 25 lines of $tlog ---" | tee -a "$RESULT"
    tail -25 "$tlog" | sed 's/^/    /' | tee -a "$RESULT"
  fi
done

echo | tee -a "$LOG"
echo "=== sweep done $(date -Is) ===" | tee -a "$LOG" "$RESULT"
echo "===SWEEP_COMPLETE===" | tee -a "$RESULT"
