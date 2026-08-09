# Usage

## Update History

Run:

```text
run.cmd
```

or choose **Update History** from the configured Sierra Data folder.

The plan is built before target changes begin.

SCID processing distinguishes:

- historical replacement
- live-sensitive merge
- deferred/unsafe replacement
- already-current target

Historical Daily processing is independent.

### Live SCID handoff

The bridge does not use raw cross-feed timestamps as duplicate keys.

A live-sensitive target is merged only when Rithmic is demonstrably newer or
more complete at the endpoint and a verified handoff can be found. Evidence is
either a later whole Rithmic second, or greater Rithmic trade volume when both
files end in the same second. Raw microsecond order is never used as evidence.

The handoff requires at least three matching active seconds. Matching uses:

- total volume
- bid volume
- ask volume
- scaled last price

The boundary is half-open:

```text
SC Data:  timestamp < boundary
Rithmic:  timestamp >= boundary
```

A partial latest SC second therefore cannot cause duplicate records from both
feeds. If the newest overlap is incomplete, the bridge searches backward for a
clean verified run. If none exists, no merge is committed.

## Archive SC Data

Run:

```text
archive.cmd
```

or select one or more recognized two-digit-year SC Data `.scid` / `.dly` files
and choose **Archive SC Data**.

Destination:

```text
<DataPath>\HistoryBridge\Archive
```

Archive is restricted to SC Data source inventory. It is not a generic file
archiver.

A source is deleted only after verified GZip creation.

## Restore SC Data

Run:

```text
restore.cmd
```

or select one or more GZip files under `HistoryBridge\Archive` and choose
**Restore SC Data**.

Archive content is verified before publication.

If a different destination exists, the bridge asks before preserving it under:

```text
HistoryBridge\RestoreConflicts
```

and replacing it.

Conflict copies carry `--UN--` in their filenames because their origin is not
assumed.

## Rollback Rithmic

Run:

```text
rollback.cmd
```

or select one or more backup files under:

```text
HistoryBridge\Baselines
HistoryBridge\Rollbacks
```

Interactive selection accepts comma-separated indexes/ranges such as:

```text
1,3-5
```

A rollback batch permits only one backup per target.

The plan displays provenance for the selected backup and, when resolvable, the
current target.

### Provenance codes

```text
RT  authenticated Rithmic
SC  pure SC Data-derived
MX  mixed/hybrid
FR  foreign/non-SC form, provider not authenticated
UN  unknown
```

A mixed backup uses the compact `MX` code:

```text
manual-20260808-220000-123--MX--NQH6.CME.scid.gz
```

The exact cutover timestamp is stored in metadata and shown in rollback details when
available.

### Current-target classification

Before preserving a current target as an undo backup, the bridge resolves its
identity from actual evidence:

1. exact SHA-256 match to a known backup
2. exact SHA-256 match to bridge state
3. full relationship to the matching SC Data source
4. conservative record morphology
5. Unknown

If the file has changed, old state alone does not preserve its old label.

## Storage Report

Run:

```text
storage.cmd
```

Storage Report shows logical/on-disk usage and configured paths.

It also summarizes rollback provenance.

### Rithmic file compression

Existing uncompressed one-digit-year `.scid`/`.dly` files are reported.

With explicit confirmation and Sierra Chart closed, Storage Report can enable
Windows per-file compression and report reclaimed disk space.

Normal Update never silently recompresses existing files.

### Duplicate rollback copies

Exact rollback duplicates are grouped by:

- target
- original byte length
- SHA-256

They are reported only. Removal requires a dedicated confirmation.

## Temp files

`HistoryBridgeTemp` normally does not exist.

If it remains after an error, inspect the operation log before deleting
anything. It may contain the only current transaction recovery material.

## Multi-select

Archive, Restore and Rollback accept Explorer multi-selection.

The selection broker collects individual Explorer invocations into one batch
under `%TEMP%\SierraHistoryBridge\Explorer`, then consumes the manifest and
cleans empty broker directories.
