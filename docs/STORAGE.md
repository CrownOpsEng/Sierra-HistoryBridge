# Storage and recovery

## Configured locations

The bridge uses four configured roots:

- Sierra Chart Data
- Archive
- Recovery
- Logs

Archive, Recovery, and Logs default to subfolders of Sierra Chart Data but may
be configured on other drives.

## Archive

Persistent archives are stored under:

```text
SCID_Bridge_Archive
```

Market-data files are flat within each category:

```text
SC_Data
Rithmic_Baselines
Rollbacks
Restore_Conflicts
```

No category creates symbol, contract-year, or timestamp subdirectories.

### SC_Data

User-requested offline archives of two-digit-year SC Data `.scid` and `.dly`
files.

The archive filename is the original filename plus `.gz`.

### Rithmic_Baselines

Independent Rithmic SCID evidence retained before the bridge replaces an
existing target.

Example:

```text
NQH22-CME.scid__NQH2.CME.scid.gz
```

The two-digit source identity prevents decade ambiguity.

### Rollbacks

Verified Rithmic rollback copies retained for live/temporary merges and manual
undo points.

Examples:

```text
NQH26-CME.scid__NQH6.CME.scid.gz
manual-20260808-180000-000__NQH6.CME.scid.gz
```

### Restore_Conflicts

Verified copies of destination files preserved when an interactive SC Data
restore replaces a different existing file.

## Recovery staging

Default:

```text
SCID_Bridge_Backups
```

Recovery staging holds temporary `.bak` files used while a target is replaced.

It is not a second archive and normally returns to zero after successful
operations.

If a recovery file remains after an interrupted or failed operation, startup
does not silently repurpose or delete it.

## Logs

Default:

```text
SCID_Bridge_Logs
```

Logs are small relative to market-data files and are retained until removed by
the user.

## Temporary files

SCID conversion requires a complete temporary output before atomic publication.

The bridge checks that the destination drive has enough free space for the
expected temporary output plus a reserve.

Stale bridge temporary files older than one hour are removed at startup.

## Logical versus allocated size

Storage Report shows both:

- **Logical** — file length
- **On disk** — Windows allocation size

These can differ substantially when NTFS compression or sparse allocation is in
use.

The report distinguishes:

- **Sierra Data folder** — files physically under the configured Data folder
- **Tracked total** — Data plus configured Archive, Recovery, and Logs when
  those roots are elsewhere

Free space refers to the Sierra Data drive.

## Baseline removal

Independent Rithmic baselines can be removed from Storage Report after a final
validation confirms:

- source and target are available
- SC Data fully covers the original baseline
- current target matches the converted SC Data source
- independent source/baseline comparison is STRONG
- neither side contains out-of-order records

Uncertain baselines are kept.


## Duplicate rollback review

Exact duplicate rollback archives for the same Rithmic target are identified by:

- target filename
- uncompressed byte length
- SHA-256

Duplicates are reported with the redundant-copy count and reclaimable space.
They are not removed automatically.

Interactive Update, Storage Report, and Rollback runs report all duplicate
groups and ask before redundant copies are removed. The general `-Yes` switch
does not authorize deletion of persistent rollback backups; the duplicate
cleanup prompt requires its own confirmation.

Different rollback content is never grouped as a duplicate.


## Windows file compression

SCID files keep the same logical size regardless of file-system compression.
A large SCID therefore has the same logical byte length even when its allocated
disk usage is much smaller.

When the Data volume supports per-file compression, the bridge:

- enables compression on new temporary market-data outputs before writing their
  payload
- verifies compression on the final SCID/DLY target after publication
- restores SC Data and Rithmic market-data archives through compressed
  temporary outputs
- records logical and allocated sizes in operation logs

Existing uncompressed Rithmic targets are never compressed silently. Storage
Report identifies them and asks before enabling compression in place.

GZip archives are already compressed containers and are not part of this
in-place market-data compression workflow.
