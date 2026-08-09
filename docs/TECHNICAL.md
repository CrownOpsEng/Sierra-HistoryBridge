# Technical design

## Symbol mapping

SC Data futures filenames use a two-digit year:

```text
NQU26-CME.scid
```

Rithmic filenames use one year digit:

```text
NQU6.CME.scid
```

The bridge only creates Rithmic aliases inside a rolling window that remains
within one decade.

## Managed window

The contract window is:

```text
5 years usable history
+ 3 months rollover buffer
+ 6 months forward buffer
```

When two SC Data contracts would map to the same one-digit Rithmic filename,
the newest eligible contract owns that alias.

Unmanaged Rithmic files are never retired.

## SCID format

Sierra Chart SCID files use a 56-byte header and 40-byte records.

The conversion preserves:

- SCDateTimeMS timestamp
- trade/high/low/close semantics
- NumTrades
- TotalVolume
- BidVolume
- AskVolume
- Sierra special Open/control markers

Only positive price fields are scaled. Control-marker values are preserved
bit-for-bit.

## Price scale

The raw-price multiplier is not stored in the SCID header.

The bridge infers and stores a scale for each root/exchange group from
overlapping SCID or Historical Daily source/target files. A saved scale is used
only after it has been established from actual overlapping data.

## Historical SCID replacement

A historical target is rebuilt from the SC Data source.

The temporary output is:

1. written separately
2. durably flushed
3. structurally validated
4. checked against expected records
5. atomically published

The source and target metadata are rechecked around validation/conversion. A
changing file is deferred.

## Live-sensitive SCID handling

A current target may contain Rithmic records newer than the SC Data source.

When required, the bridge verifies at least three consecutive active seconds by
total volume, bid/ask volume, and scaled last price before selecting a handoff:

- SC Data owns records before the handoff second
- Rithmic owns the handoff second and everything newer

The target is not changed when this strict half-open boundary cannot be proven.

## Historical Daily handling

Historical Daily files are text/CSV.

For each update:

- SC Data supplies rows through its latest date
- the existing Rithmic row for that same latest date may be retained
- Rithmic dates newer than the source are retained
- older target-only dates are dropped

Daily state uses a SHA-256 source signature and verified target metadata.

## State

`state.json` uses schema version 1.

SCID state records:

- source content fingerprint
- target path
- minimum target record count
- first target timestamp
- minimum target last timestamp
- whether the SCID target is bridge-managed

Daily state records the corresponding Daily source signature and target
metadata.

Unsupported or malformed state is ignored and rebuilt from the current files.

### SCID dirty check

The SCID fingerprint contains:

- byte length
- first timestamp
- last timestamp
- deterministic sampled SHA-256

If saved state is missing, a fast distributed converted-pair check can confirm
that an existing target already matches the source without forcing a rewrite.

## Preflight validation

When an existing historical Rithmic SCID is available, the bridge compares the
source and independent reference using one-second aggregation.

A STRONG match requires:

- common coverage ≥ 99%
- exact per-second volume ≥ 98%
- last-price agreement ≥ 99%
- aggregate volume difference ≤ 0.5%

The report also records bid/ask volume, source/target richness, ordering, and
coverage notes.

A baseline captured from the original Rithmic target remains independent
cross-feed evidence. A bridge-managed target is labeled as managed consistency,
not independent cross-feed validation.

## Persistent archives

Market-data archives are flat inside their semantic category.

```text
SC_Data\
Rithmic_Baselines\
Rollbacks\
Restore_Conflicts\
```

Rithmic baseline and automatic rollback filenames include both source and
target identities:

```text
NQH22-CME.scid__NQH2.CME.scid.gz
```

This prevents one-digit-year ambiguity without directory partitioning.

Each verified archive has a `.meta` sidecar containing the information required
for validation or restore.

## Rithmic rollback

A manual rollback:

1. requires Sierra Chart to be closed
2. identifies the target from the verified backup
3. compares the current target to the selected backup
4. reuses an exact rollback copy when one already protects the current target,
   otherwise creates a verified manual undo backup
5. authorizes atomic replacement only after the existing target is protected
6. restores and verifies the selected backup
7. invalidates the corresponding saved state

The selected backup is retained.

## Recovery staging

Raw `.bak` files are temporary recovery material produced during replacement.

Successful historical replacements remove their temporary backups after
verification. Live/temporary merges retain a verified compressed rollback when
required.

Unexpected files left in Recovery are not silently converted or deleted by
startup cleanup.

## Logging

Logs use:

```text
timestamp | level | event | message
```

The console presents operational status and decisions. Detailed validation
metrics, record counts, hashes, timings, and errors are kept in logs.

## Runtime

The application targets stock Windows PowerShell 5.1 and compiles the embedded
C# engine through plain `Add-Type`.
