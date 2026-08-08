# Storage behavior

Sierra History Bridge keeps only data that serves a distinct purpose.

## Files that remain uncompressed

### SC Data source files

SC Data `.scid` files are authoritative source data. The bridge does not
automatically delete, move, or compress them because Sierra Chart may use them
directly.

### Rithmic-named files inside the rolling window

The converted one-digit-year `.scid` files must remain normal Sierra Chart data
files while they are in the managed Rithmic window.

This source/target duplication is inherent to the bridge: the two services use
different filenames and raw price representations.

## Compressed archives

Archives are stored under:

```text
SierraChart\Data\SCID_Bridge_Archive
```

### Original Rithmic baseline

Before the first bridge replacement of an independent Rithmic file, preflight
compares both feeds. The original Rithmic file is then retained as:

```text
Rithmic_Baselines\<SC-contract>\<original-Rithmic-filename>.gz
```

A `.meta` sidecar records the uncompressed length, record count, first and last
timestamps, original write time, and SHA-256.

The archive is verified by decompressing and hashing it before the raw baseline
is deleted. Future cross-feed validation reads the archive directly through
streaming decompression. It does not create a full-size extraction.

### Live/temporary rollback

A live or temporary merge keeps one compressed previous target:

```text
Rollbacks\<SC-contract>\<original-Rithmic-filename>.gz
```

A newer successful live/temporary replacement can replace this rollback after
the new compressed archive has itself been verified.

### Legacy backups

Raw `.scid.bak` and `.dly.bak` files left by older bridge builds are not assumed
to be disposable. They may contain the only untouched Rithmic data.

On startup they are moved into verified compressed legacy archives using a
timestamp directory. This both preserves the evidence and prevents one-digit
filenames from colliding later.

## Temporary and recovery files

A safe SCID conversion needs one complete temporary output before replacing the
target. This is the main unavoidable peak-space requirement.

Conversions are sequential. Before a temporary SCID is created, the converter
calculates the exact expected output length and checks free space on the target
drive. The output plus a 256 MiB reserve must fit. Otherwise the update is
deferred before the target is changed.

Raw `.bak` files created during replacement are retained until the new target
passes post-replacement verification.

After verification:

- historical SCID `.bak`: deleted
- Historical Daily `.bak`: deleted
- live/temporary SCID `.bak`: compressed to the single rollback archive
- first independent Rithmic baseline: compressed to its immutable baseline
  archive

If compression fails, the raw recovery file is left in place rather than being
deleted.

At startup, abandoned `.scbridge.tmp`, `.dailybridge.tmp`, and archive `.tmp`
files older than one hour are removed.

## Retiring old Rithmic targets

A bridge-generated Rithmic target that moves outside the rolling Rithmic
history window is not archived again when it can be regenerated from the SC
Data source. It is removed after saved metadata confirms that it is the
bridge-managed file.

The original independent Rithmic baseline, when captured, remains in compressed
form.

## Small files

Logs, state, configuration, Historical Daily source files, archive metadata,
and the installed setup payload are small relative to tick SCID files. The
bridge does not add complexity to save insignificant amounts of space there.

## Failure policy

Storage cleanup never deletes an unverified unknown SCID file.

If a file cannot be identified or an archive cannot be verified, the original
is left untouched and a warning is reported.


## Logical size versus disk usage

Storage reporting includes both logical byte size and allocated/on-disk usage.
On NTFS-compressed or sparse Sierra data, these can be very different. Archive,
restore, update, and cleanup reports therefore show a before/delta/total view
using allocated usage while retaining logical totals for reference.

## User-managed SC Data archives

Long-term SC Data remains online by default because Sierra Chart can use it
directly. The bridge never archives those files merely because they are old.

`archive.cmd` is an explicit space-management operation. It validates each
selected `.scid`/`.dly`, writes a GZip archive, decompresses and hashes the
archive for verification, and only then removes the original. `restore.cmd`
performs the inverse operation with the same byte-count/SHA-256 checks and an
atomic destination update.

Archive filters are based on futures contract month rather than file
modification time.


## Allocated size

The Windows storage report now reads `FILE_STANDARD_INFO.AllocationSize`,
the file-system allocation value used for actual disk consumption, rather than
estimating allocation from logical length. This is especially important for
NTFS-compressed or sparse Sierra Chart data.

Archive, recovery, and log folders may be configured on separate locations.
The storage report displays those configured paths. Free-space reporting remains
anchored to the Sierra Data drive; individual archive/restore operations perform
their own destination-drive free-space checks before writing.


## Recovery staging

`Recovery staging` is the configured `SCID_Bridge_Backups` directory. It is not
a second archive. It is short-lived transactional storage used while a target
is being replaced. Verified historical backups are normally removed after a
successful replacement; live rollback evidence is compressed into the bridge
archive. A steady-state installation can therefore show zero bytes in Recovery
staging.


## Empty bridge directories

Archive/restore and startup housekeeping remove empty bridge-created directory
trees from the deepest directory upward. The configured top-level Archive,
Recovery, and Logs folders are retained, but empty internal paths such as:

```text
SCID_Bridge_Archive\SC_Data\NQ-CME\2000
```

are removed after their final archive/metadata file is removed.

## Rithmic baseline cleanup

Original Rithmic baselines are independent validation evidence, not permanent
required data. Storage Report shows their count and disk usage and can perform a
verified cleanup.

A baseline is deleted only after all of these checks pass immediately before
removal:

1. the SC Data source and current Rithmic-named target both exist;
2. SC Data covers the complete original Rithmic baseline time range;
3. the current target matches the converted SC Data source;
4. a full independent source-vs-compressed-baseline validation is `STRONG`;
5. neither side contains out-of-order records.

Anything uncertain is retained. After deletion, empty `Rithmic_Baselines`
directory structures are pruned automatically.


## Prune-on-delete rule

Every bridge-owned file removal uses a standard cleanup routine. Immediately
after deleting the file, the bridge walks upward from its parent directory and
removes every empty directory until it reaches the nearest configured base
folder.

The protected base folders are Sierra Data, Archive, Recovery, and Logs. The
most specific matching base wins. When Archive is a child of Data, deleting the
last file from:

```text
Archive\SC_Data\NQ-CME\2000
```

removes `2000`, `NQ-CME`, and `SC_Data`, but never the configured Archive folder
or Sierra Data folder.

The same rule is used by restore, baseline removal, archive temporary cleanup,
recovery cleanup, and target retirement. A final full housekeeping sweep remains
as a fallback. Persistent cleanup failures are reported instead of silently
leaving an unexplained orphan.


## Context-menu working directory

A File Explorer context-menu process can inherit a working directory inside the
folder containing the selected archive. Windows does not allow a process to
remove its own current directory.

Archive/restore therefore relocates both the PowerShell FileSystem provider
location and the Win32 process current directory to the configured Sierra Data
base before file operations begin. The prune-on-delete routine also performs
this check defensively before removing each empty directory.

This prevents the bridge itself from holding `SC_Data\<group>\<year>` open
while trying to delete it.


## Deferred cleanup for externally locked folders

Immediate prune-on-delete remains the normal path. If Windows reports an empty
bridge folder as `in use`, the bridge no longer repeats the same warning and
give up.

The folder is queued for post-exit cleanup. A separate hidden PowerShell process
waits for the main Sierra History Bridge process to exit, then retries the
empty-directory chain for up to 30 seconds. This specifically handles locks
whose lifetime is tied to a File Explorer context-menu invocation or the
launched process.

The helper never removes non-empty directories and never crosses the configured
Data/Archive/Recovery/Logs base boundary. Results are written to
`SCID_Bridge_Logs\cleanup-*.log`.


## SC Data archive layout

`SC_Data` is intentionally flat, matching Sierra Chart's Data folder. The
original filename already identifies root, contract month/year, exchange, and
file type. Additional group/year directories add no useful identity and get in
the way of bulk restore.

Legacy nested archives are migrated automatically. A different archive already
occupying the intended flat filename is never overwritten.
