#!/bin/bash
#
# Apply OSv platform patches to OpenZFS
#
# This script applies the OSv-specific platform layer patches to the
# OpenZFS submodule. It should be run after 'git submodule update' and
# before building.
#
# The patches add the complete OSv platform layer to OpenZFS 2.3.6:
# - Platform headers (include/os/osv/zfs/sys/)
# - Platform implementation (module/os/osv/zfs/)
# - ~16,700 lines of OSv-specific code
#
# Usage:
#   ./scripts/apply-openzfs-patches.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSV_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENZFS_DIR="$OSV_ROOT/external/openzfs"
PATCHES_DIR="$OSV_ROOT/patches/openzfs"

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

cd "$OPENZFS_DIR"

# Check current commit
CURRENT_COMMIT=$(git rev-parse --short HEAD)
EXPECTED_COMMIT="c840612ee"  # zfs-2.3.6 tag

if [[ "$CURRENT_COMMIT" != "$EXPECTED_COMMIT" ]]; then
    echo "Warning: OpenZFS is at commit $CURRENT_COMMIT"
    echo "Expected: $EXPECTED_COMMIT (zfs-2.3.6)"
    echo ""
fi

# Check if patches are already applied
if [[ -f "module/os/osv/zfs/zfs_vnops_os.c" ]]; then
    echo "OSv platform files already exist - patches may be applied"
    echo ""
    read -p "Reapply patches? (will reset submodule) [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping patch application"
        exit 0
    fi

    echo "Resetting OpenZFS to clean state..."
    git reset --hard zfs-2.3.6
    git clean -fd
    echo ""
fi

# Apply patches
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
echo "Base: zfs-2.3.6 + OSv platform patches"
echo ""

# Verify key files exist
echo "Verifying key platform files..."
KEY_FILES=(
    "include/os/osv/zfs/sys/zfs_context_os.h"
    "module/os/osv/zfs/vdev_disk.c"
    "module/os/osv/zfs/arc_os.c"
    "module/os/osv/zfs/zfs_vnops_os.c"
    "module/os/osv/zfs/zfs_znode_os.c"
)

ALL_GOOD=true
for file in "${KEY_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "  ✓ $file"
    else
        echo "  ✗ $file (MISSING)"
        ALL_GOOD=false
    fi
done

echo ""
if [[ "$ALL_GOOD" == "true" ]]; then
    echo "✓ All key platform files present"
    echo ""
    echo "OpenZFS is ready for building!"
else
    echo "✗ Some platform files are missing"
    echo "Please check patch application"
    exit 1
fi
