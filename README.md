# Sierra History Bridge

**Version 0.0.33**

Sierra History Bridge maintains Rithmic-named Sierra Chart history from Sierra
Chart SC Data sources while preserving newer Rithmic records when a safe,
verified cutover can be established.

Sierra History Bridge is open-source software licensed under the
[Mozilla Public License 2.0](LICENSE).

## Storage layout

The bridge treats the Sierra installation and Sierra Data folder as separate
paths so multiple Sierra installations and relocated Data folders are supported.

Default paths:

```text
<SierraPath>\Logs\HistoryBridge

<DataPath>\HistoryBridge\
├── Archive\
├── Baselines\
├── Rollbacks\
└── RestoreConflicts\

<DataPath>\HistoryBridgeTemp
```

`HistoryBridge` and its category folders are created only when needed and are
removed when empty.

`HistoryBridgeTemp` is same-volume transaction storage. It normally does not
exist. If an interrupted operation leaves recovery material, the folder remains
and is reported rather than discarded.

Application settings and state remain under:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

The default application installation remains:

```text
C:\Program Files\Sierra History Bridge
```

## Update History

Run:

```text
run.cmd
```

or use **Update History** from the configured Sierra Data folder.

The bridge:

- scans eligible two-digit-year SC Data contracts
- resolves the one-digit-year Rithmic target
- verifies the price scale
- evaluates source/target consistency
- builds a plan before changing files
- writes verified SCID and Historical Daily targets
- preserves a newer Rithmic SCID tail only when a safe whole-second handoff is
  proven

Generated/restored market-data files use Windows file compression when the Data
volume supports it.

### SCID merge boundary

Sierra SC Data and Rithmic can describe the same trades with different
intra-second timestamps and different record forms. The bridge therefore never
deduplicates across feeds by raw timestamp.

For a live-sensitive merge:

1. the Rithmic target must be demonstrably newer/more complete at the endpoint:
   either it extends into a later **whole second**, or it has greater trade
   volume when both feeds end in the same second
2. the bridge searches the trailing overlap for a clean run of at least three
   matching active seconds
3. each matched second must agree on total volume, bid volume, ask volume and
   scaled last price
4. the selected second becomes an atomic half-open boundary
5. SC Data contributes records strictly **before** the boundary
6. Rithmic contributes records **at or after** the boundary

If the boundary cannot be proved, the target is not changed.

This prevents one handoff second from being represented by both feeds even when
their raw record timestamps differ.

## Archive SC Data

**Archive SC Data** accepts only recognized two-digit-year SC Data `.scid` and
`.dly` source files.

Destination:

```text
<DataPath>\HistoryBridge\Archive
```

A source is removed only after its GZip archive has been verified.

`Archive` has one meaning: **SC Data archive**. It does not accept arbitrary
Rithmic targets through the supported Archive operation.

## Restore SC Data

**Restore SC Data** restores one or more files from:

```text
<DataPath>\HistoryBridge\Archive
```

If a different destination already exists and the user confirms replacement,
the existing destination is first preserved under:

```text
<DataPath>\HistoryBridge\RestoreConflicts
```

Restore-conflict filenames carry `--UN--` because their content origin is not
assumed.

## Rithmic Baselines and Rollbacks

### Baselines

```text
<DataPath>\HistoryBridge\Baselines
```

is an invariant: it contains only bridge-authenticated Rithmic baseline states.

A new baseline is admitted only when the independent pre-replacement target:

- passes STRONG cross-feed consistency
- is monotonic
- has native Rithmic-style record morphology
- has no Sierra special Open control markers

Questionable or malformed baseline files are preserved under `Rollbacks` as
unknown rather than remaining in `Baselines`.

### Rollbacks

```text
<DataPath>\HistoryBridge\Rollbacks
```

contains undo/recovery states. Their source classification is visible directly
in the filename.

Codes:

```text
RT  authenticated Rithmic baseline identity
SC  pure SC Data-derived target
MX  mixed/hybrid SC Data + preserved Rithmic tail
FR  non-SC/foreign record form; provider not authenticated
UN  origin cannot be proved safely
```

Examples:

```text
NQH22-CME.scid--RT--NQH2.CME.scid.gz
NQH26-CME.scid--SC--NQH6.CME.scid.gz
manual-20260808-220000-123--MX--NQH6.CME.scid.gz
manual-20260808-220100-456--FR--NQH6.CME.scid.gz
manual-20260808-220200-789--UN--NQH6.CME.scid.gz
```

For `MX`, the filename stays compact. The `.meta` file retains the exact Sierra
cutover timestamp and UTC display value.

## Provenance evidence

The bridge does not trust a filename or stale state entry as proof of current
content.

Evidence is resolved in this order:

1. exact SHA-256 identity to an authenticated baseline or known backup
2. exact SHA-256 identity to bridge state for the same target
3. full record relationship to the matching SC Data source
4. conservative SCID record-morphology evidence
5. `UN` when the evidence is insufficient

If a file changes, saved provenance is no longer authenticated unless the new
file exactly matches known evidence. Changed files are reclassified from their
actual content/source relationship.

`FR` is deliberately separate from `RT`: looking non-SC does not prove that a
file came from Rithmic.

## Rollback Rithmic

**Rollback Rithmic** supports one or more selected backup files.

A batch:

- permits only one selected backup per Rithmic target
- shows selected-backup provenance before confirmation
- evaluates current-target provenance when possible
- preserves a verified undo state before replacement
- restores each target as its own verified transaction
- reports restored, already-current and failed targets

Exact duplicate rollback copies are reported. Removal requires its own explicit
confirmation; duplicates are not silently deleted.

## Storage Report

Storage Report shows logical and allocated disk usage for:

```text
SC Data sources
Rithmic targets
HistoryBridge
Temp files
Logs
Other Data
Sierra Data folder
Tracked total
Free space
```

It also shows the resolved Sierra/Data/Storage/Temp/Logs paths and summarizes
Rithmic backup provenance.

Existing uncompressed Rithmic `.scid`/`.dly` files can be compressed in place
only after explicit confirmation and with Sierra Chart closed.

## Explorer multi-select

Archive, Restore and Rollback support Explorer multi-selection.

Explorer file invocations are collected temporarily under:

```text
%TEMP%\SierraHistoryBridge\Explorer
```

and passed to one visible bridge process as a complete selection. Consumed and
stale broker files are cleaned automatically.

## Safety model

The bridge favors a safe no-change result over an ambiguous replacement.

Important protections include:

- no raw-timestamp cross-feed deduplication
- whole-second half-open SCID cutovers
- three-second handoff confirmation
- source and target change detection during conversion
- monotonic timestamp checks
- output record/first/last validation
- exact output SHA-256 recorded during the write pass
- durable `Flush(true)`
- verified GZip byte count and SHA-256
- explicit conflict/duplicate confirmation
- lazy temporary storage with recovery preservation
