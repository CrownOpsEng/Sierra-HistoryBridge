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
