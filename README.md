# Sierra History Bridge

**Version 0.0.25**

Sierra History Bridge updates Rithmic-named Sierra Chart history files from
matching SC Data files.

SCID and Historical Daily files are discovered independently. A contract does
not need to have both file types.

```text
NQU26-CME.scid  ->  NQU6.CME.scid
NQU26-CME.dly   ->  NQU6.CME.dly
NQZ23-CME.dly   ->  NQZ3.CME.dly
```

The `.scid` path supplies intraday/tick history. The `.dly` path supplies
Historical Daily data used by Sierra Chart for Daily and higher-timeframe
Historical charts.

Rithmic remains the service configured in the Sierra Chart installation.
SC Data source files are not modified.

## Install

Extract the Windows release and run:

```text
setup.cmd
```

Setup supports current-user and all-users installation and can optionally
create Start Menu shortcuts.

After installation, right-click the configured Sierra Chart `Data` folder
itself and choose:

```text
Update Sierra history from SC Data
```

Relevant `.scid`, `.dly`, SC Data archive, and Rithmic backup files receive
scoped archive/restore/rollback context-menu actions. The bridge does not add a
global blank-space menu to unrelated folders.

## Update behavior

The application scans the Sierra Chart Data folder, applies the managed history
window, verifies the raw-price scale, and shows the update plan before changing
files.

Historical updates can run while Sierra Chart remains open. Archive, restore,
and rollback operations that move or replace source/target files wait for Sierra
Chart to close. Recent SCID bridge updates use explicit live-file safety choices.

### Intraday files

For `.scid` files:

- SC Data records are converted to the verified Rithmic raw-price scale.
- Trade, volume, bid/ask volume, timestamps, and Sierra control markers are
  preserved.
- Rithmic records sufficiently newer than the end of the SC Data source are
  retained.
- Output is validated before the target is replaced.

### Historical Daily files

When a matching SC Data `.dly` file exists, it is processed with the same
contract mapping and price scale.

Daily files are merged by date:

- SC Data supplies the historical rows through its latest date.
- If the Rithmic target already contains that latest date, the Rithmic row is
  retained for that date.
- Rithmic rows newer than the SC Data file are retained.
- Older Rithmic-only rows are not carried forward.
- When SC Data advances to a newer date, the previous latest date is replaced
  from SC Data on the next run.

This prevents an actively updating daily record from being replaced by a
less-current Historical Daily record while allowing completed dates to converge
to SC Data.

## Rolling Rithmic history window

Rithmic futures symbols use one year digit. Sierra Chart also limits Continuous
Futures Contract charts using single-digit-year symbols to five years.

The bridge manages:

```text
5 years history
+ 3 months older rollover buffer
+ 6 months forward-contract buffer
```

Older SC Data files remain under their two-digit-year names and are not
converted to conflicting Rithmic filenames.


## Sierra Chart while updating

Sierra Chart does not normally need to be closed for historical updates.

The bridge distinguishes recent SCID targets from historical files. A SCID
update is treated as live-sensitive when its source or target timestamps reach
the recent-data window. File modification time alone does not make an old
historical target live-sensitive.

When Sierra Chart is running and a live-sensitive SCID update is required, the
application offers:

1. disconnect Sierra Chart and close the affected chartbooks, then update all
2. close Sierra Chart, then update all
3. skip the live SCID update and continue with the remaining historical/DLY
   work, when remaining work exists
4. cancel

When only historical files are being updated, Sierra Chart can remain open.
Charts that were already open should use **Chart > Reload and Recalculate**
afterward so they reread their chart-data files from disk.

The application does not silently mark a skipped live SCID source as processed.
It will remain eligible on the next run.

## Storage, archives, and logs

The bridge minimizes persistent duplicate data.

```text
SierraChart\Data\SCID_Bridge_Archive
SierraChart\Data\SCID_Bridge_Backups
SierraChart\Data\SCID_Bridge_Logs
```

`SCID_Bridge_Archive` contains compressed `.gz` evidence/recovery files. The
archive filename is the original Sierra filename plus `.gz`, so removing the
`.gz` suffix gives the original filename.

The first independent Rithmic SCID used for cross-feed validation is retained
as a compressed immutable baseline under
`SCID_Bridge_Archive\Rithmic_Baselines\<SC-contract>`. Future preflight
validation reads that baseline directly through streaming decompression; it
does not extract another multi-gigabyte copy.

Historical `.scid.bak` files created during atomic replacement are deleted
after the new target passes post-replacement validation because the target can
be regenerated from its SC Data source. For live or temporary merges, one
compressed rollback is retained instead. Historical Daily `.bak` files are
also removed after successful verification.

`SCID_Bridge_Backups` is therefore a recovery/staging directory, not a
permanent second copy of every target. A raw backup is left there only when it
cannot be safely pruned or compressed.

At startup the bridge removes stale temporary conversion files older than one
hour and safely prunes/compresses leftover bridge backups. It reports free
space and reclaimed space before scanning. Each SCID update also checks free
space before creating its full-size temporary output and defers the update
instead of filling the drive.

SC Data source files are not automatically deleted or compressed. They are the
authoritative originals and may still be needed directly by Sierra Chart.
Likewise, bridge-generated Rithmic targets outside the rolling window are not
redundantly archived when they can be regenerated; the independent compressed
Rithmic baseline remains available when one was captured.

## Repair and uninstall

Run `setup.cmd` again to repair/update or uninstall. Dedicated `repair.cmd` and
`uninstall.cmd` commands are also included. Installed copies can be removed
through Windows Settings → Apps → Installed apps.

## Project status

Version 0.0.25 is the initial release. The SCID path has been exercised against
real NQ SC Data and Rithmic files during development, including historical
replacement, live-aware handling, archive/restore, Rithmic rollback, storage
reporting, and Windows PowerShell 5.1 integration. Historical Daily handling
follows Sierra Chart's text/CSV format and is covered by the project self-test.

This project is not affiliated with or endorsed by Sierra Chart, Rithmic,
CME Group, or their affiliates.

## Documentation

- [Installation and maintenance](docs/INSTALLATION.md)
- [Usage](docs/USAGE.md)
- [Technical design](docs/TECHNICAL.md)
- [Storage behavior](docs/STORAGE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Development](docs/DEVELOPMENT.md)
- [Publishing](docs/PUBLISHING.md)
- [Contributing](CONTRIBUTING.md)
- [Security and data integrity](SECURITY.md)

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE).


## Existing Rithmic files outside the managed range

The bridge does not remove arbitrary Rithmic history files merely because they
are outside the managed range.

Files previously recorded by the bridge can be retired after their saved
metadata is verified. Unmanaged files are left alone.

When a one-digit Rithmic filename is reused by a newer decade, processing the
new eligible SC Data contract replaces the old target history. The SCID path
preserves only genuinely newer target records. The Historical Daily path keeps
only the overlapping latest date and dates newer than the source, so old-decade
daily rows are not carried into the new contract.


## SCID replacement policy

Expired/historical SCID contracts are pure SC Data replacements. No Rithmic
records are appended to a historical target. Because SCID uses a fixed 56-byte
header and fixed 40-byte records, a successful historical replacement has the
same byte length and record count as its SC Data source.

Newer Rithmic records are preserved only for a live-sensitive contract whose
target is demonstrably newer or more complete at the endpoint. The bridge
requires at least three consecutive active seconds with matching volume,
bid/ask volume, and scaled last price. The selected second is a half-open
boundary: SC Data owns records before it and Rithmic owns records at or after
it. If the boundary cannot be proven, the target is not changed.

The source and, when applicable, live target are checked again before the
temporary output is published. If either file changed during conversion, the
temporary output is discarded and the SCID update is deferred.

For historical contracts with matching Daily data, the bridge also checks that
the intraday source reaches the end of the Daily contract history. A source
that is still being downloaded is deferred rather than converted as a partial
historical file.

## Validation before replacement

When an SC Data SCID and an existing Rithmic SCID overlap, the bridge uses both
files to validate the proposed history update before replacing anything. It
compares timestamp coverage, ordering, per-second volume, bid/ask volume,
last price after scale conversion, aggregate volume, and data richness.

Incomplete downloads and material cross-feed differences are reported before
processing. The default action is to leave the existing Rithmic file untouched.
When the overlap validates strongly and Rithmic only supplies a later missing
segment, an optional temporary merge can be used without marking the contract
complete; the bridge will revisit it on the next run.

For repeatable cross-feed validation, the first untouched Rithmic target is
preserved as an immutable compressed baseline. The archive keeps the original
Rithmic filename as `<original-filename>.gz` beneath the two-digit SC contract
directory, preventing one-digit-year collisions. Historical rolling backups
are discarded after verification; live/temporary merges retain one compressed
rollback.


## Optional archive and restore

SC Data history is never archived automatically. Keeping the two-digit SC Data
files in the Sierra Chart `Data` folder keeps that history immediately usable
by Sierra Chart.

When disk space is needed, use **Archive Historical Data** from the Start Menu
or run:

```text
archive.cmd
```

The default selection is contracts older than the bridge's rolling Rithmic
window. Before changing anything, the archive tool shows the contract range,
file count, logical size, and actual disk usage and asks for confirmation.
Other selections can be made by contract date range, by contract age in days,
or explicitly all source contracts.

Archives are verified GZip files under:

```text
SCID_Bridge_Archive\SC_Data
```

The original Sierra filename is preserved as `<original-filename>.gz`. The
source is removed only after the compressed archive decompresses to the exact
same byte count and SHA-256 hash. Sierra Chart must be closed because archived
source files disappear from its active `Data` folder.

Use **Restore Historical Data** or:

```text
restore.cmd
```

to return archives to the exact original filenames. The default restores the
most recent archived contract; date-range, recent-days, and all filters are
also available. A successful restore removes the archive copy so the same data
is not stored twice. If a different file already exists at the destination, it
is never silently overwritten; interactive restore can preserve the existing
file in a verified conflict archive before replacing it.

Use **Storage Report** or `storage.cmd` at any time to show both logical file
size and allocated/on-disk usage. This distinction matters on NTFS-compressed
or sparse files, where Explorer can report a much larger `Size` than
`Size on disk`.


## Very early NQ Daily data

The bridge preserves Historical Daily rows exactly, including zero-volume rows.
It does not synthesize volume or settlement data.

The earliest E-mini Nasdaq-100 Daily history can contain zero-volume records or
missing contract dates. These conditions are reported as source-data quality
notes rather than silently "repaired." They can limit volume-based or
back-adjusted continuous-contract calculations at the beginning of the
available history.


## File Explorer integration

The installer remembers the Sierra Chart Data folder and can optionally place
the bridge archive, recovery, and log folders elsewhere.

Explorer commands are deliberately scoped rather than added to every folder:

- right-click the configured Sierra Data **folder itself** for Update and
  Storage Report;
- right-click `.scid` or `.dly` files directly inside the configured Data
  folder for **Archive SC Data source**;
- right-click recognized `.gz` files below the configured bridge archive for
  **Restore Sierra history archive**.

The bridge does not install a global blank-space/background command. Windows'
static `Directory\Background` verbs cannot be reliably filtered by the current
folder using `AppliesTo`; making that menu truly dynamic requires an in-process
Shell extension. Avoiding that Explorer-loaded component keeps v0.0.25 simpler
and reduces the risk of slowing or destabilizing File Explorer.

Archive and restore now wait interactively when Sierra Chart is open. Close all
Sierra Chart instances and press Enter; the operation continues in the same
window after the process is gone.


## Fast change detection and full validation

Normal runs do not use Windows file modification time as proof that an SCID
source changed. SCID state now uses a stable structural/content fingerprint
(length, first/last timestamps, and deterministic record samples). Existing
v0.0.25 state which used modification time is migrated without rewriting files
when the structural source identity is unchanged.

If saved provenance is stale or missing but the current Rithmic-named target
already has the expected converted structure and sampled record contents, the
bridge restores its managed-state metadata instead of needlessly rewriting the
contract.

Complete cross-feed/file validation remains available when a historical SCID
really changed or its state is unknown. Because that operation scans entire
multi-gigabyte files, interactive runs ask once before beginning it. Choosing
No defers those SCID updates and leaves all affected files untouched.


## Archive housekeeping

The bridge owns its internal archive directory structure and removes empty
internal directories after archive/restore operations. The configured top-level
Archive/Recovery/Logs folders remain available, but empty contract/year trees
do not accumulate.

Storage Report also offers optional removal of original Rithmic baseline
archives after a final independent validation proves that the complete SC Data
source and current converted target are sound. This cleanup is never automatic.


## No orphaned bridge folders

Bridge-owned file deletion now prunes empty parent directories immediately,
stopping only at a configured base folder. Cleanup no longer depends solely on
an end-of-operation directory sweep.


## Utility operation logs

Archive, Restore, and Storage operations now create their own timestamped logs
under the configured Logs folder, alongside the existing bridge/preflight logs.

If Windows keeps an otherwise-empty bridge folder locked during a context-menu
operation, the bridge queues that folder for a detached post-exit cleanup
worker. The helper waits until the visible bridge process exits, retries the
empty-folder removal for up to 30 seconds, and writes a `cleanup-*.log`
recording what was removed or what remained locked.


## Flat SC Data archive

User-managed SC Data archives mirror Sierra Chart's flat market-data directory.
All archived source files are stored directly under:

```text
SCID_Bridge_Archive\SC_Data
```

Examples:

```text
NQH00-CME.dly.gz
NQZ14-CME.scid.gz
NQM20-CME.scid.gz
```

There are no market-group or year subdirectories. The Sierra filename already
contains the contract identity, and a flat layout makes bulk browsing and mass
restore much easier.

Archives created by older bridge builds under paths such as
`SC_Data\NQ-CME\2000` are automatically moved into flat `SC_Data` the next time
Archive, Restore, or Storage Report runs. Empty legacy folders are pruned.


## Rithmic backup rollback

When the bridge preserves an original Rithmic baseline or a live/temporary
rollback backup, the compressed backup can be restored directly.

Right-click a recognized `.gz` file under `Rithmic_Baselines`, `Rollbacks`, or
`Legacy_Backups` and choose **Rollback Rithmic data**, or run:

```text
rollback.cmd
```

Rollback requires Sierra Chart to be closed. If the current target exists and
differs from the selected backup, the bridge first creates a new verified manual
rollback of the current target. It then restores and verifies the selected
backup and invalidates the corresponding bridge state so the next Update
re-evaluates that target.

The selected backup is retained after rollback. This makes rollback reversible
instead of consuming the safety copy.
