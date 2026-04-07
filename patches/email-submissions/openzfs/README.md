# OpenZFS Email Submission Patches

This directory contains email-ready patches for submitting the OSv OpenZFS 2.3.6 integration to the OpenZFS mailing list.

## Files

- `0000-cover-letter.patch` - Cover letter explaining the patch series
- `0001-OSv-Add-complete-platform-layer-with-SPL-for-OpenZFS.patch` - Platform layer and SPL implementation
- `0002-feat-zfs-Add-OSv-OS-layer-implementation-with-auto-u.patch` - File operations and auto-upgrade feature

## Submission Instructions

### Prerequisites

1. Subscribe to the OpenZFS mailing list:
   - Visit: https://github.com/openzfs/zfs#mailing-lists
   - Subscribe to the developer list

2. Configure git send-email:
   ```bash
   git config sendemail.to "openzfs-developer@lists.openzfs.org"
   git config sendemail.from "Your Name <your.email@example.com>"
   ```

### Sending Patches

1. **Test patches apply cleanly to upstream**:
   ```bash
   cd /tmp
   git clone https://github.com/openzfs/zfs.git
   cd zfs
   git checkout zfs-2.3.6
   git am /path/to/osv/patches/email-submissions/openzfs/*.patch
   ```

2. **Send patches via git send-email**:
   ```bash
   git send-email \
     --to openzfs-developer@lists.openzfs.org \
     --cc greg@burd.me \
     patches/email-submissions/openzfs/*.patch
   ```

3. **Alternative: Manual email**:
   - Use each .patch file as an email
   - Send to: openzfs-developer@lists.openzfs.org
   - Maintain threading (In-Reply-To headers)

### Patch Format Verification

Each patch should have:
- `From:` line with author information
- `Date:` line with timestamp
- `Subject:` line with [PATCH N/M] prefix
- Commit message body
- `Signed-off-by:` line
- `---` separator
- Diffstat
- Actual diff

Verify with:
```bash
for patch in patches/email-submissions/openzfs/*.patch; do
  echo "Checking $patch"
  grep -q "^From: " "$patch" && echo "  ✓ Has From"
  grep -q "^Subject: " "$patch" && echo "  ✓ Has Subject"
  grep -q "^Signed-off-by: " "$patch" && echo "  ✓ Has Signed-off-by" || echo "  - No Signed-off-by (OK for cover)"
  grep -q "^---$" "$patch" && echo "  ✓ Has diff separator"
done
```

## Patch Content Summary

### Patch 0 (Cover Letter)
- Explains motivation (cloud unikernel with ZFS)
- Describes architecture (platform-split model)
- Lists design decisions
- Provides testing summary
- Total line count

### Patch 1 (Platform Layer)
- 46 SPL headers (include/os/osv/spl/sys/)
- 7 platform headers (include/os/osv/zfs/sys/)
- 15 core implementation files (module/os/osv/zfs/)
- ~15,400 lines

### Patch 2 (File Operations & Auto-Upgrade)
- File/directory operations
- Platform-specific implementations
- Automatic pool upgrade feature
- ~1,300 lines

## Response Guidelines

After submission, monitor the mailing list for:
- Review comments
- Questions about design decisions
- Requests for changes
- Testing feedback

Be prepared to:
- Explain OSv-specific design choices
- Provide additional testing results
- Iterate on feedback
- Resubmit as [PATCH v2] if needed

## Regenerating Patches

If changes are needed after review:

1. Make changes in the OpenZFS submodule:
   ```bash
   cd external/openzfs
   # Make your changes
   git commit --amend  # or create new commits
   ```

2. Regenerate email patches:
   ```bash
   git format-patch --signoff --cover-letter zfs-2.3.6..HEAD \
     -o ../../patches/email-submissions/openzfs/
   ```

3. Update cover letter (0000-cover-letter.patch) with v2 notes

4. Send as [PATCH v2]:
   ```bash
   git send-email --subject-prefix="PATCH v2" \
     patches/email-submissions/openzfs/*.patch
   ```

## References

- OpenZFS Development Guide: https://openzfs.github.io/openzfs-docs/Developer%20Resources/
- OpenZFS Mailing Lists: https://github.com/openzfs/zfs#mailing-lists
- git send-email Guide: https://git-send-email.io/
- OSv Project: https://github.com/cloudius-systems/osv
