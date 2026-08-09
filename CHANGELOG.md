# Changelog

## v0.0.32 - 2026-08-08

Experimental release.

### History

- maps two-digit SC Data futures files to one-digit Rithmic target filenames
- supports SCID and Historical Daily files independently
- verifies price scaling from overlapping source/target data
- replaces historical SCIDs from SC Data
- preserves a genuinely newer or more complete Rithmic tail only after a
  verified whole-second handoff
- maintains a five-year history window with rollover and forward buffers
- never retires unmanaged Rithmic files

### Validation

- stable sampled SCID source fingerprints
- Historical Daily SHA-256 source signatures
- optional full SCID preflight validation
- independent Rithmic baseline validation
- explicit distinction between cross-feed and managed consistency
- source/target rechecks around conversion and publication

### Archive and recovery

- flat SC Data archive
- flat Rithmic baseline and rollback categories
- verified GZip archive/restore
- Rithmic rollback with verified undo protection and atomic target replacement
- exact duplicate Rithmic rollback backups are reported and can be cleared with explicit confirmation
- duplicate rollback review is compatible with Windows PowerShell 5.1 collection binding
- Rollback reports duplicate groups across all Rithmic rollback targets before proceeding
- restore conflict preservation
- temporary recovery staging
- bridge-owned empty-directory cleanup

### Storage and Windows integration

- generated and restored market-data targets use verified Windows file compression when supported
- Storage Report detects existing uncompressed Rithmic targets and offers confirmed in-place compression
- normal Update reports uncompressed existing targets without modifying them automatically

- logical and allocated/on-disk storage reporting
- configurable Data, Archive, Recovery, and Logs folders
- scoped Explorer commands
- Explorer file commands support multi-select batches through one selection broker
- Archive, Restore, and Rollback process Explorer multi-selections in one visible operation
- Rollback manual selection accepts comma-separated indexes and ranges
- optional Start Menu shortcuts
- Windows Installed apps registration
- repair and uninstall
- structured update, preflight, utility, cleanup, and setup logs
- Windows PowerShell 5.1 runtime
