# Documentation Archive

This directory contains historical project documentation and tracking documents that are no longer actively maintained in the main documentation tree.

## Contents

These documents were created during the OpenZFS migration project to track progress and maintain detailed implementation notes. They have been preserved for reference but are superseded by the main documentation in `docs/`.

### Status Documents

The following status documents have been archived:

- **IMPLEMENTATION_STATUS.md** - Historical implementation progress tracking
- **PR_READINESS_REVIEW.md** - Pre-PR review checklist and status
- **OPENZFS_BUILD_ISSUE.md** - Build issue troubleshooting notes
- **OPENZFS_BUILD_STATUS.md** - Build system integration status
- **TESTING_STATUS_SUMMARY.md** - Test execution results summary
- **CURRENT_STATUS.md** - Point-in-time status snapshot
- **SESSION_COMPLETE.md** - Session completion notes
- **FEATURE_STATUS.md** - Feature implementation checklist

For current documentation, refer instead to:
- **docs/OPENZFS_MIGRATION.md** - For user-facing migration guidance
- **docs/OPENZFS_TESTING.md** - For comprehensive testing procedures
- **docs/OPENZFS_INTEGRATION_OVERVIEW.md** - For technical architecture

### Project Tracking

Detailed project tracking and implementation progress notes should be maintained in:
- GitHub Issues or Project boards
- OSv Google Group discussions
- Commit messages (via `git log`)

### For Developers

If you need to understand the evolution of the OpenZFS integration:

1. Start with `docs/OPENZFS_INTEGRATION_OVERVIEW.md` for architecture
2. Review commits: `git log --oneline | head -20`
3. Check related features in `docs/` directory

---

**Archive Date**: April 2026
**Project**: OpenZFS 2.3.6 Integration for OSv
