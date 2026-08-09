# Troubleshooting

## Setup cannot find Sierra Chart Data

Run the bridge directly with:

```text
run.cmd
```

Enter the Sierra Chart Data folder when prompted, then run Repair to store the
correct location.

## Explorer commands do not appear

Run:

```text
repair.cmd
```

For an all-users installation, approve the administrator prompt.

On Windows 11 check **Show more options**.

Explorer commands are intentionally scoped to the configured Data and Archive
paths.

## Sierra Chart is running during archive, restore, or rollback

Close every Sierra Chart instance and press Enter in the bridge window.

These operations move or replace files that Sierra Chart may have open.

## A live SCID cannot be updated

Use the live-file prompt to:

- disconnect Sierra Chart and close the affected chartbooks
- close Sierra Chart
- skip the live SCID and continue
- cancel

A skipped SCID remains eligible on the next run.

## Full validation takes a long time

Full validation scans complete SCID files.

When prompted, choose No to defer those SCIDs and continue without changing
them.

## Source changed during validation or conversion

The bridge defers the file when source or target metadata changes during a
safety-sensitive operation.

Allow the SC Data download or Rithmic write activity to finish, then run Update
again.

## Insufficient disk space

SCID conversion requires a full temporary output plus a safety reserve.

Use Storage Report and free space on the Sierra Data drive or move persistent
Archive/Logs to another drive.

## Recovery staging contains files

A file in `SCID_Bridge_Backups` can indicate an interrupted or failed
replacement.

Do not delete it until the corresponding target and operation log have been
reviewed.

## Empty archive directory cannot be removed

The bridge retries empty-folder cleanup and can defer cleanup until the current
process exits.

Check the matching `cleanup-*.log` if the folder remains.

A folder that remains locked after the cleanup retry is being held by another
process.

## A rolled-back target changes on the next Update

Rollback restores the selected Rithmic backup; it does not disable normal
bridge management.

The rollback invalidates saved state intentionally. The next Update evaluates
the restored target against current SC Data.

## Historical Daily zero-volume rows

The bridge preserves source rows exactly.

Zero-volume rows in early Historical Daily data are reported as source-data
notes. They are not synthesized or silently altered.

## Reporting an integrity problem

Collect:

- Sierra History Bridge version
- Windows version
- Sierra Chart version
- source and target filenames
- relevant bridge/preflight/utility log
- whether Sierra Chart was open

Do not include credentials or unrelated trading records.


## Rithmic files use much more disk than expected

Compare **Logical** and **On disk** in Storage Report.

If Rithmic logical size is expected but On disk is nearly the same size, run
Storage Report. It will report any uncompressed Rithmic market-data files and
offer to enable Windows file compression.

Sierra Chart must be closed while existing files are compressed.

If the Data volume does not support per-file compression, the bridge reports
that condition and leaves the files unchanged.


## Only one file appears from an Explorer multi-selection

Run Repair to refresh the Explorer verb registration.

Current file verbs use the `Player` multi-select model and hidden selection
broker. A valid multi-selection should open one bridge window containing the
complete Archive, Restore, or Rollback batch.

If multiple bridge windows appear or a utility log reports a sharing/stream
error immediately after a context-menu action, Repair the installation and
retry. Stale Explorer registration can still point directly at the operation
instead of the selection broker.
