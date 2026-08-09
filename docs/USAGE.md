# Usage

## Update History

Run:

```text
run.cmd
```

or right-click the configured Sierra Data folder and choose **Update History**.

A normal run:

1. loads the conversion engine
2. resolves configured storage
3. removes stale bridge temporary files
4. scans the managed contract window
5. verifies price scaling
6. checks saved state and source/target integrity
7. performs preflight validation when required
8. shows the update plan
9. applies confirmed changes
10. verifies each published file and writes the operation log

### Full SCID validation

When changed or unknown historical SCIDs require full-file validation, the
interactive run asks once before beginning the long scan.

Choosing No defers those SCID updates. It never treats them as validated.

A live-sensitive merge preserves a Rithmic tail only after matching trade
aggregates prove a whole-second handoff. SC Data contributes records before the
boundary and Rithmic contributes records at or after it.

### Sierra Chart running

Historical updates can run while Sierra Chart remains open.

If a live-sensitive SCID requires replacement, the bridge offers explicit
options to disconnect/close affected charts, close Sierra Chart, skip the live
SCID, or cancel.

Reload open charts after an update with:

```text
Chart > Reload and Recalculate
```

## Archive SC Data

Run:

```text
archive.cmd
```

or right-click a two-digit-year SC Data `.scid` / `.dly` file and choose
**Archive SC Data**.

Selections can be made by:

- default: outside the managed Rithmic window
- contract date range
- contract age in days
- all SC Data source files

The source file is removed only after the GZip archive is decompressed and
verified against the original byte count and SHA-256 hash.

Archives are stored flat under:

```text
SCID_Bridge_Archive\SC_Data
```

Sierra Chart must be closed because the source file is removed from its active
Data folder.

## Restore SC Data

Run:

```text
restore.cmd
```

or right-click an archive in `SC_Data` and choose **Restore SC Data**.

Restore can select:

- most recent archived contract
- contract date range
- recent contract months
- all archives

A successful restore removes the archive copy. If a different destination file
already exists, the bridge can preserve that file as a verified conflict backup
before replacement.

## Rollback Rithmic

Run:

```text
rollback.cmd
```

or right-click a verified backup in `Rithmic_Baselines` or `Rollbacks` and
choose **Rollback Rithmic**.

Interactive rollback lists available backups and restores one selection.

If the current target differs from the selected backup, the bridge first
ensures an exact verified undo backup exists in `Rollbacks`. An existing exact
rollback copy is reused; otherwise a timestamped manual undo backup is created.

The selected backup is retained. The corresponding saved bridge state is
invalidated so the next Update evaluates the restored target normally.

## Storage Report

Run:

```text
storage.cmd
```

or right-click the configured Data folder and choose **Storage Report**.

The report shows logical and allocated/on-disk usage for:

- SC Data sources
- Rithmic targets
- archive
- recovery staging
- logs
- other Data-folder files
- Sierra Data folder total
- total tracked storage
- free space on the Data drive

When independent Rithmic baselines are present, Storage Report can perform a
final validation and remove baselines that are no longer needed.

## Logs

Detailed operation logs are written to the configured Logs folder.

Use the console for current progress and decisions; use logs for validation
metrics, record counts, timings, hashes, warnings, and error details.


### Duplicate rollback review

Rollback backup identity is based on the Rithmic target, uncompressed byte
length, and SHA-256. Exact duplicates are reported; they are never removed
without confirmation.

Update, Storage Report, and Rollback can surface duplicate rollback groups.
Interactive runs ask whether redundant copies should be removed while keeping
one verified copy of each exact state.


### Rithmic file compression

New SCID and Historical Daily targets are written with Windows file compression
when the Data volume supports it.

Storage Report scans existing one-digit-year Rithmic `.scid` and `.dly` files.
If uncompressed files are found, it reports their logical/on-disk usage and
asks:

```text
Enable NTFS compression for these Rithmic market-data files? [y/N]
```

Choosing Yes requires Sierra Chart to be closed. The bridge compresses each
file in place, verifies the compressed attribute, records before/after
allocation in the log, and reports reclaimed disk space.

Normal Update only reports existing uncompressed targets and points to Storage
Report; it does not modify them automatically.
