# Technical design

## Purpose

Sierra Chart data-service symbols and Rithmic symbols can use different filenames and different raw price representation inside SCID records. Sierra History Bridge converts the historical SC Data records into the verified Rithmic convention while retaining the richer SC Data trade information.

## SCID structure

The converter expects Sierra Chart's documented intraday structure:

```text
56-byte file header
40-byte records
```

Each record contains:

```text
DateTime
Open
High
Low
Close
NumTrades
TotalVolume
BidVolume
AskVolume
```

For a single-trade/tick record, Sierra Chart gives the price fields special meaning:

- `Open` can be zero or a control marker for unbundled trades
- `High` contains the ask at the trade
- `Low` contains the bid at the trade
- `Close` contains the trade price

The bridge therefore scales `Open` only when it is positive. Zero and negative control-marker values are preserved bit-for-bit.

## Scale verification

A service-specific scale is not assumed from the filename.

For each root/exchange group, the bridge finds an overlapping SC Data source and Rithmic target, samples prices across the shared time range, computes the target/source price ratio, and verifies that the observed median is close to a supported power-of-ten scale.

The verified scale is stored by group, for example:

```text
NQ|CME
```

Once verified, expired contracts in the same group can be created even when no original Rithmic file exists for that contract.

## Historical authority and live tail

For an existing Rithmic target:

1. SC Data is authoritative through the latest source timestamp
2. Rithmic records sufficiently newer than the SC source are retained
3. a short boundary guard prevents common live/backfill overlap from being carried into the new file

## Conversion sequence

For each source:

1. validate SCID header and record alignment
2. read records in large chunks
3. verify monotonic timestamps
4. scale price-bearing fields
5. preserve trade and volume fields
6. append the eligible newer Rithmic tail
7. flush the temporary output
8. validate representative records
9. atomically replace the target and create a rolling backup

## Validation

The converter verifies:

- SCID magic and layout
- record alignment
- monotonic source timestamps
- output record count
- first timestamp
- sampled timestamp preservation
- `NumTrades`
- `TotalVolume`
- `BidVolume`
- `AskVolume`
- bitwise preservation of non-positive `Open` markers
- expected scaled trade prices

## Installation architecture

Executable application files are installed separately from mutable state.

Program files use the Windows application-program location appropriate to the selected installation scope. Per-user configuration and processing state remain under the user's local application-data directory.

Explorer integration and the Installed apps entry are registered according to the selected installation scope.



## Windows PowerShell compilation

Setup, repair, the self-test, and normal application startup all load the
embedded C# SCID engine through the same stock Windows PowerShell 5.1 command:

```powershell
Add-Type -Path $ConverterSource
```

The converter deliberately avoids unsafe code, LINQ, and custom compiler
parameters so PowerShell's normal default framework references are retained.


## Out-of-order source timestamps

SCID files can occasionally contain a timestamp that moves backward even
though the record sequence itself is the intended trade-data sequence.

The bridge does not sort records or rewrite timestamps. It preserves the
source record sequence exactly, counts timestamp inversions, reports the first
one and the largest backward jump, and records those diagnostics in the run
log.

This policy avoids silently changing trade ordering while still allowing an
otherwise usable SC Data file to be converted.
