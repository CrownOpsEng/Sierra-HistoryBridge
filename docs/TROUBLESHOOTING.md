# Troubleshooting

## Repair fails before installation

Repair validates the exact package PowerShell and C# before replacing the
installed application.

The existing installed program is not replaced by a package that fails
pre-copy validation.

Use the reported parser/compiler line to diagnose the package.

## A file appears in Baselines but is not authenticated RT

Run Repair.

`HistoryBridge\Baselines` is an invariant. Repair verifies baseline evidence.
Anything it cannot authenticate is preserved under Rollbacks rather than left
in Baselines.

If Repair cannot move the questionable file safely, Repair stops instead of
silently weakening the invariant.

## A rollback says FR

`FR` means the data is structurally non-SC/foreign relative to the SC Data
representation, but provider identity is not authenticated.

It does **not** mean “definitely Rithmic.”

An exact match to an authenticated RT baseline can promote the same content to
RT.

## A rollback says UN

`UN` means the bridge does not have enough evidence for a safe classification.

When possible, the bridge checks:

- exact known backup hash
- exact saved target hash
- full relationship to matching SC Data
- record morphology

Unknown is preferable to assigning the wrong source identity.

## Where is the MX cutover timestamp?

MX filenames stay compact:

```text
manual-...--MX--NQH6.CME.scid.gz
```

The verified SC Data -> Rithmic cutover is stored in the `.meta` file and can be
shown in rollback details.

## Could different SC/Rithmic microsecond timestamps duplicate trades?

The bridge does not splice on raw timestamp.

The same trade activity can have different intra-second timestamps across the
two feeds.

The bridge selects a verified whole-second boundary and writes:

```text
SC Data < boundary
Rithmic >= boundary
```

At least three matching active seconds are required before a boundary is
accepted. If a clean boundary cannot be proven, the merge is deferred/failed
without replacing the target.

## Temp files remain

Check:

```text
<DataPath>\HistoryBridgeTemp
```

The folder normally does not exist.

If nonempty, it may contain recovery material from an interrupted operation.
Review the operation log before deleting it.

Empty Temp storage is removed automatically.

## Only one file appears from Explorer multi-select

Run Repair to refresh Explorer integration.

Archive, Restore and Rollback should open one visible operation containing the
full selected batch.

Transient selection state is under:

```text
%TEMP%\SierraHistoryBridge\Explorer
```

## Rithmic files use more disk than expected

Run Storage Report and compare Logical vs On disk.

If existing Rithmic targets are uncompressed, Storage Report can enable Windows
file compression after confirmation. Sierra Chart must be closed.

## Duplicate rollback backups

Duplicates are reported by exact target/length/SHA identity.

They are never removed automatically. Use the dedicated confirmation if you want
redundant copies removed.

## Wrong Sierra instance or Data folder

Run Repair and review:

```text
Sierra
Data
Storage
Temp
Logs
```

SierraPath and DataPath are independent so multiple installations and relocated
Data folders are supported.

## RestoreConflict filename says UN

A conflicting destination is arbitrary existing data. The bridge preserves it
before replacement but does not assume its source identity, so it is named
`--UN--` unless separate evidence establishes otherwise.


## A rollback restored to a composite filename

A prior build could interpret a malformed composite backup stem such as
`NQH22-CME.scid-NQH2.CME.scid` as a Rithmic target. Current Repair recognizes
that form, resolves the terminal target as `NQH2.CME.scid`, fixes recoverable
backup names/metadata, and refuses restore when a target cannot be established
safely.

An already-created composite file in the active Data folder is not deleted
automatically because its contents may be unique. Review it before removing it.


## Header-only backup appears

Current builds do not preserve zero-record SCID/DLY files.

Run Update, Storage Report, Archive, Restore or Rollback once. Startup storage
cleanup removes any bridge-owned header-only archive left by an earlier build.

If the file is malformed rather than a valid zero-record market-data file, it
is deliberately left untouched and logged for review.
