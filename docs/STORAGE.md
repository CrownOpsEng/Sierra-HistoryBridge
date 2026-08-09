# Storage

## Path model

Default storage domains:

```text
<DataPath>\HistoryBridge
<DataPath>\HistoryBridgeTemp
<SierraPath>\Logs\HistoryBridge
```

Application settings/state:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

## Persistent storage

```text
<DataPath>\HistoryBridge\
├── Archive\
├── Baselines\
├── Rollbacks\
└── RestoreConflicts\
```

All categories are lazy.

### Archive

Contains only SC Data source files archived through **Archive SC Data**.

These archives may be the only remaining local copy of historical SC Data and
are persistent user data.

### Baselines

Contains only authenticated Rithmic baseline states.

The folder is an invariant, not a general backup area.

A candidate enters Baselines only after bridge checks prove:

- independent pre-replacement target
- STRONG SC Data/Rithmic overlap consistency
- monotonic target data
- native Rithmic-style Open record morphology
- no Sierra special Open control sentinels

A file that cannot satisfy this invariant is retained under Rollbacks with
conservative identity instead of remaining in Baselines.

Example:

```text
NQH22-CME.scid--RT--NQH2.CME.scid.gz
```

### Rollbacks

Contains undo/recovery states.

Filename identity codes:

```text
RT  authenticated Rithmic
SC  pure SC Data-derived
MX  mixed/hybrid
FR  foreign/non-SC record form; provider not authenticated
UN  insufficient identity evidence
```

Examples:

```text
NQH26-CME.scid--SC--NQH6.CME.scid.gz
manual-20260808-220000-123--MX--NQH6.CME.scid.gz
manual-20260808-220100-456--FR--NQH6.CME.scid.gz
```

For `MX`, the filename remains compact. Metadata stores the exact Sierra cutover
timestamp and UTC display value.

### RestoreConflicts

Contains destinations preserved before an explicit SC Data restore replacement.

Because the bridge cannot safely assume the origin of an arbitrary conflicting
destination, the filename and metadata use Unknown unless stronger evidence is
available.

Example:

```text
20260808-220300--UN--NQH26-CME.scid.gz
```

## Provenance evidence

Provider/source identity is never inferred from naming alone.

Priority:

1. exact SHA-256 identity to authenticated backup evidence
2. exact SHA-256 identity to bridge state
3. full deterministic relationship to the corresponding SC Data file
4. conservative record morphology
5. Unknown

### SCID morphology

During SCID GZip creation, the same sequential pass used for compression and
SHA-256 also counts Open-field forms:

```text
special_control_open_records
regular_open_records
zero_open_records
other_open_records
```

Content classes:

- `SCDataLike`
- `Mixed`
- `ForeignLike`
- `Unclassified`

Morphology is useful evidence but has limits:

- `ForeignLike` can establish `FR`, not `RT`
- `SCDataLike` alone does not prove pure SC because a live tail can include
  zero-Open records
- a clean segmented `Mixed` structure can support MX when a valid cutoff is
  visible
- exact hash/source relationship is stronger evidence

### Changed files

State stores exact hashes for bridge-published targets.

If a current file no longer has the saved exact SHA-256, saved provenance is
not treated as current identity. The file is classified again from available
backup/source/content evidence.

This prevents stale state from silently labeling a modified file.

## Temp files

```text
<DataPath>\HistoryBridgeTemp
```

contains same-volume transaction staging.

Lifecycle:

```text
no temp work       -> folder absent
transaction starts -> create lazily
success + empty    -> remove automatically
recovery remains   -> preserve and report
```

The installer does not create it.

Temporary output files that must be atomically published can also exist briefly
beside their final target and are subject to bridge stale-temp housekeeping.

## Logs

```text
<SierraPath>\Logs\HistoryBridge
```

contains:

```text
update-*.log
archive-*.log
restore-*.log
rollback-*.log
storage-*.log
cleanup-*.log
setup.log
```

## Windows file compression

SCID logical byte length does not change with Windows file compression.

Storage Report therefore distinguishes:

- Logical
- On disk

Bridge-generated/restored market data is compressed at the file level when the
volume supports it.

Existing uncompressed targets require explicit user confirmation.

## GZip archive verification

Persistent archives use verified GZip containers.

Verification includes:

- original byte length
- SHA-256
- SCID structural validation where applicable

Archive/restore operations do not delete the source before the verified archive
exists.

## Cleanup policy

Automatic cleanup is restricted to bridge-proven temporary or empty material:

- stale bridge temp files
- empty `HistoryBridgeTemp`
- empty category folders
- empty `HistoryBridge`
- stale/consumed Explorer broker files

Persistent Archive, Baselines, Rollbacks and RestoreConflicts content is not
silently deleted.

Exact duplicate rollback removal always requires confirmation.


## Header-only market-data files

A structurally valid market-data file with zero records is a placeholder, not
recoverable history. History Bridge never keeps such a file as persistent
backup evidence.

For SCID this means a valid 56-byte SCID header with zero 40-byte records. For
Historical Daily it means a recognized Daily header with zero data rows.

Header-only files are therefore:

- rejected by the SCID/DLY archive writers
- rejected as SCID restore payloads
- not used as Rithmic undo backups
- not placed in `RestoreConflicts`
- discarded from temporary replacement backup staging
- removed from existing bridge-owned Archive/Baselines/Rollbacks/
  RestoreConflicts storage during cleanup

Only positively identified zero-record files receive this treatment. Invalid,
unreadable or ambiguous files remain untouched and are reported.
