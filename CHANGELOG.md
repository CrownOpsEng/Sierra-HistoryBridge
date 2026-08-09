# Changelog

## v0.0.25 - 2026-08-08

Initial release.

### History bridge

- maps two-digit SC Data futures files to Rithmic one-digit-year filenames
- converts SCID raw prices using a verified root/exchange scale while preserving
  timestamps, trade/volume fields, bid/ask volume, and Sierra control markers
- processes SCID and Historical Daily files independently
- uses complete SC Data replacement for historical SCIDs and a verified
  whole-second handoff for genuinely newer or more complete live targets
- validates output before atomic replacement and defers on source/target changes
- manages a five-year Rithmic history range with a three-month rollover buffer
  and six-month forward buffer
- never removes unmanaged Rithmic files

### Validation and state

- distinguishes independent `CROSS-FEED` validation from managed consistency
- performs full overlapping-feed preflight checks for timestamp coverage,
  ordering, per-second volume, bid/ask volume, last price, aggregate volume, and
  data richness
- asks before lengthy full historical validation; declining leaves those SCIDs
  untouched and deferred
- uses stable SCID content fingerprints and semantic DLY checks so timestamp-only
  file changes do not trigger unnecessary rewrites
- preserves zero-volume/early Historical Daily source records as supplied and
  reports source-quality notes instead of fabricating data

### Storage, archive, and recovery

- reports logical size and Windows allocated/on-disk usage by category
- distinguishes physical Sierra Data-folder usage from total tracked usage when
  archive/recovery/log folders are configured elsewhere
- uses temporary recovery staging for safe replacement
- keeps verified compressed original Rithmic baselines for independent evidence
- keeps rollback backups for live/temporary merges and manual rollback undo
- can remove eligible baselines after a final strong independent validation
- optional verified SC Data GZip archive and atomic restore
- flat user archive layout under `SCID_Bridge_Archive\SC_Data`
- archive/restore filtering by contract date range, contract age/days, or all
- safely migrates legacy nested SC Data archives into the flat layout
- removes stale bridge temporary files and prunes bridge-owned empty directories

### Rithmic rollback

- context-menu and interactive rollback for recognized Rithmic baseline,
  rollback, and legacy backup archives
- requires Sierra Chart to be closed before target replacement
- preserves a different current target as a new verified manual undo backup
- verifies restored bytes/hash and retains the selected backup
- invalidates matching bridge state so the next Update re-evaluates the target

### Windows integration

- current-user and all-users installation
- repair/update and uninstall support, including Windows Installed apps
- configurable Sierra Data, Archive, Recovery, and Logs folders
- Start Menu shortcuts for update, archive, restore, rollback, storage, repair,
  documentation, and uninstall
- Explorer commands scoped to configured Sierra folders and relevant file types
- no global blank-space menu
- interactive archive/restore/rollback waits for Sierra Chart to close instead
  of terminating the operation
- Archive, Restore, Rollback, Storage, preflight, bridge, and deferred-cleanup
  logging
- Windows PowerShell 5.1-compatible application and embedded C# engine

### Project

- self-tests for SCID conversion, Historical Daily processing, compressed
  baseline round-trip, and data-integrity behavior
- package syntax/layout/build tests
- Windows CI workflow
