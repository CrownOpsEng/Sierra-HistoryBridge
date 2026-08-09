# Changelog

## v0.0.26 - 2026-08-08

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
- Rithmic rollback with manual undo backup
- restore conflict preservation
- temporary recovery staging
- bridge-owned empty-directory cleanup

### Storage and Windows integration

- logical and allocated/on-disk storage reporting
- configurable Data, Archive, Recovery, and Logs folders
- scoped Explorer commands
- optional Start Menu shortcuts
- Windows Installed apps registration
- repair and uninstall
- structured update, preflight, utility, cleanup, and setup logs
- Windows PowerShell 5.1 runtime
