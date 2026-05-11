#!/bin/bash
#
# update-openzfs.sh - Update or re-apply OSv patches on top of OpenZFS
#
# Usage:
#   ./scripts/update-openzfs.sh [new-tag]
#
#   new-tag: Optional OpenZFS release tag to update to (e.g. zfs-2.5.0).
#            If omitted, re-applies current patches to the current base tag.
#
# This script manages the OSv-specific commits layered on top of an OpenZFS
# release tag in external/openzfs.  The workflow is:
#
#   1. Detect the OpenZFS base tag (most recent tag reachable from HEAD).
#   2. Export OSv-specific commits above that tag as patches/openzfs/*.patch.
#   3. If a new tag was given, reset the submodule to that tag and re-apply.
#   4. Verify the result and print a summary.
#
# The outer repo's submodule pointer is updated automatically after a
# successful re-application so that "git add external/openzfs" is all that
# is needed before committing.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENZFS_DIR="$OSV_ROOT/external/openzfs"
PATCHES_DIR="$OSV_ROOT/patches/openzfs"
APPLY_SCRIPT="$SCRIPT_DIR/apply-openzfs-patches.sh"

NEW_TAG="${1:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[update-openzfs] $*"; }
warn()  { echo "[update-openzfs] WARNING: $*" >&2; }
die()   { echo "[update-openzfs] ERROR: $*" >&2; exit 1; }

require_submodule() {
    if [[ ! -d "$OPENZFS_DIR/.git" && ! -f "$OPENZFS_DIR/.git" ]]; then
        die "OpenZFS submodule not initialised at $OPENZFS_DIR" \
            "Run: git submodule update --init --recursive"
    fi
}

# Detect the most recent OpenZFS release tag reachable from HEAD.
# OpenZFS tags look like zfs-2.4.1, zfs-2.3.6, etc.
detect_base_tag() {
    git -C "$OPENZFS_DIR" describe --tags --abbrev=0 --match 'zfs-*' 2>/dev/null \
        || die "Could not detect an OpenZFS release tag reachable from HEAD." \
               "Make sure the submodule has fetch tags: git -C external/openzfs fetch --tags"
}

# Return the number of commits above $1 in the submodule.
commits_above() {
    git -C "$OPENZFS_DIR" rev-list --count "${1}..HEAD"
}

# Check for uncommitted changes in the submodule.
check_clean_submodule() {
    local dirty
    dirty=$(git -C "$OPENZFS_DIR" status --porcelain 2>/dev/null)
    if [[ -n "$dirty" ]]; then
        die "The submodule has uncommitted changes." \
            "Commit or stash them before running this script." \
            "(cd external/openzfs && git status)"
    fi
}

# Save OSv-specific commits above $base_tag as patches in $PATCHES_DIR.
save_patches() {
    local base_tag="$1"
    local count
    count=$(commits_above "$base_tag")

    if [[ $count -eq 0 ]]; then
        warn "No commits above $base_tag — nothing to save."
        return 0
    fi

    info "Saving $count OSv-specific commit(s) above $base_tag to $PATCHES_DIR/ ..."

    # Clear old patches so numbering stays consistent.
    rm -f "$PATCHES_DIR"/*.patch

    git -C "$OPENZFS_DIR" format-patch \
        "${base_tag}..HEAD" \
        -o "$PATCHES_DIR/" \
        --quiet

    local saved
    saved=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l)
    info "Saved $saved patch file(s)."
}

# Apply patches from $PATCHES_DIR onto the current HEAD of the submodule.
apply_patches() {
    local patch_count
    patch_count=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l)

    if [[ $patch_count -eq 0 ]]; then
        die "No patches found in $PATCHES_DIR — nothing to apply."
    fi

    info "Applying $patch_count patch(es) ..."

    for patch in "$PATCHES_DIR"/*.patch; do
        local name
        name=$(basename "$patch")
        info "  Applying: $name"

        if ! git -C "$OPENZFS_DIR" \
                -c commit.gpgsign=false \
                am --whitespace=fix "$patch" 2>&1; then
            echo ""
            echo "--------------------------------------------------------------"
            echo "PATCH APPLICATION FAILED: $name"
            echo ""
            echo "The patch did not apply cleanly.  To resolve manually:"
            echo ""
            echo "  cd $OPENZFS_DIR"
            echo "  # Edit conflicting files, then:"
            echo "  git add <resolved-files>"
            echo "  git -c commit.gpgsign=false am --continue"
            echo ""
            echo "To abort and restore the pre-patch state:"
            echo "  git -C $OPENZFS_DIR am --abort"
            echo "  git -C $OPENZFS_DIR reset --hard ${current_base_tag:-HEAD}"
            echo "--------------------------------------------------------------"
            exit 1
        fi
    done
}

# Verify that the key OSv platform directories/files exist after patching.
verify_platform_files() {
    info "Verifying OSv platform files ..."

    local key_dirs=(
        "include/os/osv"
        "module/os/osv"
    )
    local key_files=(
        "include/os/osv/zfs/sys/zfs_context_os.h"
        "module/os/osv/zfs/vdev_disk.c"
        "module/os/osv/zfs/arc_os.c"
        "module/os/osv/zfs/zfs_vfsops.c"
        "module/os/osv/zfs/kmod_core.c"
    )

    local all_ok=true

    for d in "${key_dirs[@]}"; do
        if [[ -d "$OPENZFS_DIR/$d" ]]; then
            info "  [ok] $d/"
        else
            warn "  [MISSING] $d/"
            all_ok=false
        fi
    done

    for f in "${key_files[@]}"; do
        if [[ -f "$OPENZFS_DIR/$f" ]]; then
            info "  [ok] $f"
        else
            warn "  [MISSING] $f"
            all_ok=false
        fi
    done

    if [[ "$all_ok" != "true" ]]; then
        die "One or more expected OSv platform files are missing after patching."
    fi
}

# Print a summary after successful operation.
print_summary() {
    local base_tag="$1"
    local patch_count
    patch_count=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l)
    local head_commit
    head_commit=$(git -C "$OPENZFS_DIR" rev-parse --short HEAD)
    local header_count impl_count
    header_count=$(find "$OPENZFS_DIR/include/os/osv" -type f 2>/dev/null | wc -l)
    impl_count=$(find "$OPENZFS_DIR/module/os/osv"    -type f 2>/dev/null | wc -l)

    echo ""
    echo "============================================================"
    echo " OSv OpenZFS Update Complete"
    echo "============================================================"
    echo " Base tag    : $base_tag"
    echo " Patches     : $patch_count"
    echo " HEAD        : $head_commit"
    echo " Headers     : $header_count files in include/os/osv/"
    echo " Impl        : $impl_count files in module/os/osv/"
    echo "============================================================"
    echo ""
    echo "Next steps:"
    echo "  git add external/openzfs patches/openzfs/"
    echo "  git commit -m 'zfs: update OpenZFS base to $base_tag'"
    echo ""
}

# ---------------------------------------------------------------------------
# Update apply-openzfs-patches.sh to reflect new base tag
# ---------------------------------------------------------------------------
update_apply_script() {
    local new_base="$1"
    if [[ ! -f "$APPLY_SCRIPT" ]]; then
        warn "apply-openzfs-patches.sh not found; skipping update."
        return 0
    fi
    # Replace any hard-coded 'git reset --hard zfs-X.X.X' line
    sed -i "s|git reset --hard zfs-[0-9][0-9.]*|git reset --hard ${new_base}|g" \
        "$APPLY_SCRIPT"
    info "Updated $APPLY_SCRIPT to reference $new_base."
}

# ---------------------------------------------------------------------------
# Idempotency check
# ---------------------------------------------------------------------------
check_already_done() {
    local desired_base="$1"
    local current_base
    current_base=$(detect_base_tag)

    if [[ "$current_base" == "$desired_base" ]]; then
        local count
        count=$(commits_above "$desired_base")
        if [[ $count -gt 0 ]]; then
            local patch_count
            patch_count=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l)
            if [[ $patch_count -eq $count ]]; then
                info "Already at $desired_base with $count OSv commit(s) applied."
                info "Nothing to do.  Use --force to re-apply anyway."
                exit 0
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_submodule
check_clean_submodule

current_base_tag=$(detect_base_tag)
info "Current OpenZFS base tag: $current_base_tag"

if [[ -n "$NEW_TAG" ]]; then
    # ------------------------------------------------------------------
    # Update mode: move to a new OpenZFS tag and re-apply OSv patches
    # ------------------------------------------------------------------
    info "Target tag: $NEW_TAG"

    # Idempotency: if we're already at new tag + patches saved, skip.
    # (Only check if target == current to avoid false positive.)
    if [[ "$NEW_TAG" == "$current_base_tag" ]]; then
        check_already_done "$NEW_TAG"
    fi

    # Verify the tag exists in the submodule's local refs.
    if ! git -C "$OPENZFS_DIR" rev-parse --verify "refs/tags/$NEW_TAG" \
            >/dev/null 2>&1; then
        die "Tag '$NEW_TAG' not found in $OPENZFS_DIR." \
            "Fetch it first: git -C external/openzfs fetch --tags"
    fi

    # Step 1: Save current OSv patches from commits above current base.
    save_patches "$current_base_tag"

    # Step 2: Reset submodule to the new tag.
    info "Resetting submodule to $NEW_TAG ..."
    git -C "$OPENZFS_DIR" reset --hard "$NEW_TAG"
    git -C "$OPENZFS_DIR" clean -fd --quiet

    # Step 3: Re-apply OSv patches on top of new base.
    apply_patches

    # Step 4: Verify result.
    verify_platform_files

    # Step 5: Update apply-openzfs-patches.sh reference.
    update_apply_script "$NEW_TAG"

    print_summary "$NEW_TAG"

else
    # ------------------------------------------------------------------
    # Re-apply mode: save patches, reset to current base, re-apply
    # ------------------------------------------------------------------
    info "Re-apply mode: saving patches, resetting to $current_base_tag, re-applying."

    # Save current OSv patches.
    save_patches "$current_base_tag"

    # Reset to base tag.
    info "Resetting submodule to $current_base_tag ..."
    git -C "$OPENZFS_DIR" reset --hard "$current_base_tag"
    git -C "$OPENZFS_DIR" clean -fd --quiet

    # Re-apply.
    apply_patches

    # Verify.
    verify_platform_files

    print_summary "$current_base_tag"
fi
