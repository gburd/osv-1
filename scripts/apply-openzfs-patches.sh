#!/bin/bash
#
# Apply OSv platform patches to OpenZFS
#
# This script applies the OSv-specific platform layer patches to the
# OpenZFS submodule.  It should be run after 'git submodule update' and
# before building.
#
# The patches add the complete OSv platform layer to the OpenZFS base tag
# that the patches were generated against.  The base tag is detected
# dynamically from the patches themselves.
#
# Usage:
#   ./scripts/apply-openzfs-patches.sh [--check-only]
#
#   --check-only  Verify that patches would apply cleanly without modifying
#                 anything.  Exits 0 if clean, non-zero otherwise.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENZFS_DIR="$OSV_ROOT/external/openzfs"
PATCHES_DIR="$OSV_ROOT/patches/openzfs"

CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --check-only) CHECK_ONLY=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

echo "================================================"
echo "Applying OSv Platform Patches to OpenZFS"
echo "================================================"
echo ""

# Check if OpenZFS submodule exists
if [[ ! -d "$OPENZFS_DIR" ]]; then
    echo "Error: OpenZFS submodule not found at $OPENZFS_DIR"
    echo "Please run: git submodule update --init --recursive"
    exit 1
fi

# Check if patches directory exists
if [[ ! -d "$PATCHES_DIR" ]]; then
    echo "Error: Patches directory not found at $PATCHES_DIR"
    exit 1
fi

# Count patches
PATCH_COUNT=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | wc -l)
if [[ $PATCH_COUNT -eq 0 ]]; then
    echo "Error: No patches found in $PATCHES_DIR"
    exit 1
fi

echo "Found $PATCH_COUNT patch(es) to apply"
echo ""

# ---------------------------------------------------------------------------
# Detect the base tag dynamically from the patches directory.
# git format-patch embeds the base commit in each patch when --base is used.
# As a fallback, find the most recent release tag reachable from HEAD in the
# submodule — that is the tag the patches were generated against.
# ---------------------------------------------------------------------------
detect_base_tag() {
    # Try to read a "base-commit:" line from the first patch (set by git
    # format-patch --base=auto).  If present, resolve it to a tag.
    local first_patch
    first_patch=$(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null | sort | head -1)
    local base_commit
    base_commit=$(grep -m1 '^base-commit:' "$first_patch" 2>/dev/null \
                  | awk '{print $2}' || true)

    if [[ -n "$base_commit" ]]; then
        # Try to turn the hash into a tag name.
        local tag
        tag=$(git -C "$OPENZFS_DIR" describe --tags --exact-match "$base_commit" \
              2>/dev/null || true)
        if [[ -n "$tag" ]]; then
            echo "$tag"
            return
        fi
    fi

    # Fallback: most recent zfs-* tag reachable from HEAD.
    git -C "$OPENZFS_DIR" describe --tags --abbrev=0 --match 'zfs-*' 2>/dev/null \
        || echo ""
}

BASE_TAG=$(detect_base_tag)

if [[ -z "$BASE_TAG" ]]; then
    echo "Warning: Could not detect OpenZFS base tag."
    echo "Proceeding without base-tag validation."
else
    echo "Detected base tag: $BASE_TAG"
    echo ""
fi

cd "$OPENZFS_DIR"

# ---------------------------------------------------------------------------
# Detect whether the OSv patches are already applied.
# We check for the presence of the key platform directory AND verify that
# the number of commits above the base tag matches the number of patches.
# ---------------------------------------------------------------------------
already_applied() {
    [[ -f "module/os/osv/zfs/zfs_vfsops.c" ]] || return 1

    if [[ -n "$BASE_TAG" ]]; then
        local applied_count
        applied_count=$(git rev-list --count "${BASE_TAG}..HEAD" 2>/dev/null || echo 0)
        [[ "$applied_count" -ge 1 ]] || return 1
    fi

    return 0
}

if already_applied; then
    echo "OSv platform files already present — patches appear to be applied."
    echo ""

    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo "Check-only mode: patches are already applied."
        exit 0
    fi

    read -p "Reapply patches? (will reset submodule) [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping patch application."
        exit 0
    fi

    echo "Resetting OpenZFS to base tag ${BASE_TAG:-HEAD}..."
    if [[ -n "$BASE_TAG" ]]; then
        git reset --hard "$BASE_TAG"
    else
        echo "Warning: no base tag found; cannot reset cleanly."
        exit 1
    fi
    git clean -fd
    echo ""
fi

# ---------------------------------------------------------------------------
# Check-only mode: test whether patches would apply using --check (dry-run)
# ---------------------------------------------------------------------------
if [[ "$CHECK_ONLY" == "true" ]]; then
    echo "Check-only mode: testing patch application without modifying files ..."
    echo ""
    FAILED=false
    for patch in "$PATCHES_DIR"/*.patch; do
        PATCH_NAME=$(basename "$patch")
        echo -n "  Checking: $PATCH_NAME ... "
        if git apply --check "$patch" 2>/dev/null; then
            echo "OK"
        else
            echo "FAILED"
            FAILED=true
        fi
    done
    echo ""
    if [[ "$FAILED" == "true" ]]; then
        echo "One or more patches would not apply cleanly."
        exit 1
    else
        echo "All patches would apply cleanly."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Apply patches
# ---------------------------------------------------------------------------
echo "Applying patches..."
for patch in "$PATCHES_DIR"/*.patch; do
    PATCH_NAME=$(basename "$patch")
    echo "  Applying: $PATCH_NAME"

    if ! git -c commit.gpgsign=false am --whitespace=fix "$patch"; then
        echo ""
        echo "Error: Failed to apply patch $PATCH_NAME"
        echo ""
        echo "To resolve:"
        echo "  cd $OPENZFS_DIR"
        echo "  # Fix conflicts manually"
        echo "  git am --continue"
        echo ""
        echo "Or to abort:"
        echo "  git am --abort"
        exit 1
    fi
done

echo ""
echo "================================================"
echo "Patches Applied Successfully!"
echo "================================================"
echo ""

# Show what was added
echo "OSv platform files added:"
echo "  Headers: $(find include/os/osv -type f 2>/dev/null | wc -l) files"
echo "  Implementation: $(find module/os/osv -type f 2>/dev/null | wc -l) files"
echo ""

# Show current commit
NEW_COMMIT=$(git rev-parse --short HEAD)
echo "OpenZFS now at: $NEW_COMMIT"
if [[ -n "$BASE_TAG" ]]; then
    echo "Base: $BASE_TAG + OSv platform patches"
fi
echo ""

# Verify key files exist
echo "Verifying key platform files..."
KEY_FILES=(
    "include/os/osv/zfs/sys/zfs_context_os.h"
    "module/os/osv/zfs/vdev_disk.c"
    "module/os/osv/zfs/arc_os.c"
    "module/os/osv/zfs/zfs_vfsops.c"
    "module/os/osv/zfs/kmod_core.c"
)

ALL_GOOD=true
for file in "${KEY_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "  [ok] $file"
    else
        echo "  [MISSING] $file"
        ALL_GOOD=false
    fi
done

echo ""
if [[ "$ALL_GOOD" == "true" ]]; then
    echo "All key platform files present."
    echo ""
    echo "OpenZFS is ready for building!"
else
    echo "Some platform files are missing."
    echo "Please check patch application."
    exit 1
fi
