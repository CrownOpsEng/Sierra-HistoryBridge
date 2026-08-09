# Technical Design

## Paths and instance identity

The bridge separates:

```text
SierraPath
DataPath
StoragePath
TempPath
LogsPath
```

Defaults:

```text
StoragePath = <DataPath>\HistoryBridge
TempPath    = <DataPath>\HistoryBridgeTemp
LogsPath    = <SierraPath>\Logs\HistoryBridge
```

`TempPath` is derived from DataPath so transaction staging remains on the target
volume.

## SCID format

Supported SCID layout:

```text
Header: 56 bytes
Record: 40 bytes
```

Record fields:

```text
int64   SCDateTime
float   Open
float   High
float   Low
float   Close
uint32  NumTrades
uint32  TotalVolume
uint32  BidVolume
uint32  AskVolume
```

Positive price fields are scaled according to the verified feed factor.

Sierra special Open control markers are preserved exactly and are not treated as
prices.

## Atomic SCID publication

A replacement:

1. creates temporary output beside the target
2. enables Windows file compression when supported
3. writes converted source records and any verified target tail
4. calculates the final output SHA-256 during that same write pass
5. durably flushes with `Flush(true)`
6. checks source/target snapshots have not changed
7. validates output structure/count/first/last
8. publishes atomically
9. verifies final compression/allocation
10. finalizes transaction staging

If a pre-publication validation fails, the existing target is not replaced.

## Cross-feed merge model

Raw SCID timestamps are not cross-feed identity keys.

SC Data and Rithmic can represent the same trade activity with different
intra-second timestamps and record decomposition. The merge therefore operates
on two levels:

### Verification level: whole-second aggregates

For an active second, source and target must agree on:

```text
TotalVolume
BidVolume
AskVolume
scaled LastClose
```

`FindVerifiedHandoffDateTime` searches trailing overlap windows and requires at
least three consecutive matching active seconds.

A live tail is considered when either:

```text
floor(RithmicLast / 1 second) > floor(SCDataLast / 1 second)
```

or both files end in the same second and the Rithmic aggregate for that second
contains greater total trade volume than the SC Data aggregate.

A later microsecond in the same second is never evidence by itself. If the
same-second aggregates match, no tail is required even if the raw timestamps
differ.

### Publication level: strict half-open boundary

For selected boundary `B`:

```text
SC Data records: DateTime < B
Rithmic records: DateTime >= B
```

The engine verifies:

```text
sourceLastWritten < B
targetFirstTail   >= B
sourceLastWritten < targetFirstTail
```

Tail records are checked for monotonic order and no record before `B`.

This means there is no second in which both feeds contribute records to the
published file.

If a boundary cannot be proved:

```text
LIVE_MERGE_HANDOFF_UNVERIFIED
```

If the selected ranges do not form the required half-open relationship:

```text
LIVE_MERGE_BOUNDARY_INVALID
```

No target replacement is committed in either case.

## Daily merge model

Historical Daily data is keyed by date.

The output dictionary contains at most one record per date. Source dates are
applied, the current target's latest source date can be preserved when required,
and target dates later than the source endpoint are retained.

Daily merge therefore cannot duplicate a date row.

## Provenance model

Codes:

```text
RT = authenticated Rithmic
SC = pure SC Data-derived
MX = mixed/hybrid
FR = foreign/non-SC form; provider unauthenticated
UN = unknown
```

### Evidence hierarchy

1. exact SHA-256 match to authenticated backup
2. exact SHA-256 match to per-target bridge state
3. full source relationship to matching SC Data
4. conservative record morphology
5. Unknown

A quick signature is used only as a cache invalidator where appropriate. It is
not accepted as identity proof.

### Exact target state

The target provenance table stores:

- target path
- extension
- provenance
- source path where applicable
- scale
- exact hybrid cutover where applicable
- records / first / last
- quick signature
- exact SHA-256 when available

`ConvertResult.OutputSha256` is calculated while the output is already being
written, avoiding a second full SCID read.

When a file changes and its exact hash no longer matches state, its previous
state label is not trusted as current identity.

## SC Data relationship inspection

`InspectScidRelationshipToSource` performs deterministic record comparison
against the output that conversion of the SC Data source would produce.

Results:

- `SCData`: target is an exact converted SC prefix
- `Mixed`: exact converted SC prefix followed by a clean non-SC suffix beginning
  at a whole-second boundary, with no later exact SC records
- `Foreign`: no exact SC prefix and no later exact SC records
- `Unknown`: evidence is inconsistent or could represent modification/corruption

`InspectGzipScidRelationshipToSource` performs the same relationship analysis
directly against compressed rollback content without restoring it.

The rule requiring no later exact matches prevents a damaged SC-like file from
being mislabeled as a clean Foreign or Mixed file.

## Content morphology

The engine records:

- Sierra special negative Open markers
- regular positive Open values
- zero Open values
- other/invalid Open values

Classes:

```text
SCDataLike
Mixed
ForeignLike
Unclassified
```

Morphology never upgrades a file to RT.

## Baselines invariant

`HistoryBridge\Baselines` is restricted to authenticated Rithmic states.

Admission requires:

- current target was independent/unmanaged
- STRONG cross-feed validation
- monotonic target
- zero Sierra special Open markers
- one or more regular positive Open records
- no invalid/other Open forms

Existing baseline files are checked by Repair. An item that cannot be
authenticated is preserved under Rollbacks as UN/other conservative provenance.
Repair stops if that preservation cannot be completed safely.

Runtime baseline inventory also refuses entries whose metadata is not explicitly
Rithmic.

## Provenance filename format

General Rithmic backup format:

```text
<prefix>--<code>--<RithmicTarget>.gz
```

Mixed uses the same compact format:

```text
<prefix>--MX--<RithmicTarget>.gz
```

Metadata retains the exact SCDateTime cutover value and UTC display. The filename
does not duplicate that detail.

## Provenance metadata

`.meta` can include:

```text
provenance=
cutover_datetime=
cutover_utc=
content_class=
special_control_open_records=
regular_open_records=
zero_open_records=
other_open_records=
verified_archive_bytes=
verified_archive_write_ticks=
verified_content_sha256=
relationship_source_path=
relationship_source_bytes=
relationship_source_write_ticks=
relationship_source_signature=
relationship_scale=
relationship_result=
relationship_cutover_datetime=
```

Repair caches expensive compressed-content/source-relationship inspection.
Cache keys include archive identity and source identity/scale. Cached quick
signatures are used only to decide whether expensive inspection must be repeated.

## Windows file compression

The engine checks `FILE_FILE_COMPRESSION` and uses
`DeviceIoControl / FSCTL_SET_COMPRESSION` with
`COMPRESSION_FORMAT_DEFAULT`.

New temporary market-data outputs are marked for compression before payload
writing when supported.

Existing files are never recompressed silently.

## Explorer batching

Archive, Restore and Rollback use the Windows Player selection model.

The hidden broker uses:

```text
%TEMP%\SierraHistoryBridge\Explorer
```

Individual selection items are unique files. One leader gathers a short quiet
period of selections, writes a temporary manifest, and starts one visible
operation.

Consumed/stale broker material is removed automatically.

## Logging

Operational logs use:

```text
<SierraPath>\Logs\HistoryBridge
```

Update SCID log entries include:

```text
provenance
rithmic_tail_records
handoff_datetime
handoff_verified_trade_seconds
output_records
output_sha256
```

These fields make the exact merge identity and audit trail reproducible from
recorded evidence.


## Restore destination identity

Archive container names are never used directly as restore destinations.

- SC Data restore accepts only a basename that matches the two-digit SC Data
  contract pattern and restores to that basename under `DataPath`.
- Rithmic rollback resolves only a validated terminal one-digit Rithmic target
  from current or recognized prior composite backup forms.
- An arbitrary composite stem is never accepted as a Rithmic target.
- New GZip metadata records `original_name` from the archived source file itself,
  not from the archive container filename.
- Repair rewrites recoverable Rithmic backup metadata to the actual target
  basename and canonicalizes the filename.

This prevents a composite archive name from becoming an active Sierra data
filename.


## Zero-record preservation invariant

Persistent backup evidence must contain at least one market-data record.

The invariant is enforced at both layers:

1. operation planning refuses to create Archive/Baseline/Rollback/
   RestoreConflict evidence from a known zero-record file
2. the C# SCID and Historical Daily archive writers independently reject
   zero-record input

Compressed archive inventory can establish record count without restoring the
file. SCID count is derived from validated header/layout and uncompressed
length. Historical Daily archives are streamed through gzip and counted after
the recognized header.

Storage cleanup removes bridge-owned zero-record archives automatically because
they contain no historical market data. Cleanup does not delete malformed or
unverifiable archives.

Atomic replacement may briefly create a filesystem-level `.bak`; after a
successful replacement, a zero-record old target is deleted immediately and is
never promoted into HistoryBridge storage.
