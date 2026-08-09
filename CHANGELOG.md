# Changelog

## 0.0.33

### History update

- converts Sierra Chart SC Data history into Rithmic-named SCID targets
- synchronizes Historical Daily data
- verifies price scaling
- uses conservative preflight classification
- protects active/changing files
- retains durable `Flush(true)` publication
- uses Windows file compression for generated/restored market data when
  supported

### Cross-feed merge safety

- does not deduplicate Sierra/Rithmic records by raw timestamp
- considers live-tail merge only from whole-second/aggregate evidence: a later Rithmic second or greater Rithmic trade volume in the shared final second
- requires at least three matching active seconds using total/bid/ask volume and
  scaled last price
- publishes a strict half-open boundary: SC Data `< boundary`, Rithmic
  `>= boundary`
- validates no tail record is before the handoff
- records the verified handoff and output SHA-256

### Provenance and identity

- adds RT/SC/MX/FR/UN backup identity codes
- keeps backup filenames compact while retaining exact MX cutoff evidence in metadata/state
- stores exact provenance/cutover evidence in metadata/state
- reclassifies changed files rather than trusting stale state
- supports full source relationship inspection for live and compressed SCID
  content
- keeps `FR` distinct from authenticated `RT`

### Storage layout

- persistent storage: `<DataPath>\HistoryBridge`
- same-volume temp: `<DataPath>\HistoryBridgeTemp`
- logs: `<SierraPath>\Logs\HistoryBridge`
- application state: `%LOCALAPPDATA%\SierraHistoryBridge`
- Program Files folder remains `Sierra History Bridge`
- persistent category names: Archive, Baselines, Rollbacks, RestoreConflicts
- composite backup separator is `--`
- lazy directory creation and empty-directory cleanup

### Baselines

- Baselines is restricted to authenticated RT states
- new baseline admission requires STRONG pair consistency and native target
  morphology
- questionable/unverifiable baseline candidates are preserved in Rollbacks
  rather than left in Baselines
- Repair caches expensive archive/source relationship inspection

### Archive / restore / rollback

- Archive is restricted to recognized SC Data source inventory
- RestoreConflict backups carry UN identity
- Rollback supports multi-select batches
- one selected backup per target is enforced
- current target is protected by verified undo backup before replacement
- exact duplicate rollback removal remains explicitly confirmed

### Explorer and setup

- Archive/Restore/Rollback support Explorer multi-select through one temporary
  selection broker
- broker lives under `%TEMP%\SierraHistoryBridge\Explorer`
- SierraPath and DataPath are resolved independently
- Repair validates PowerShell/C# before replacing installed code
- Repair can relocate the immediately preceding configured folder arrangement
  into the current layout without deleting unknown material
