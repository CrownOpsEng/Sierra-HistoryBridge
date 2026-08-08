# Technical design

## Data files

Sierra Chart uses separate files for intraday and Historical Daily data:

```text
.scid   intraday data
.dly    Historical Daily data
```

The bridge processes matching files for the same futures contract and Rithmic
symbol mapping.

## SCID conversion

The converter expects Sierra Chart's documented SCID layout:

```text
56-byte header
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

For single-trade records, `Open` can contain Sierra control values instead of a
price. `Open` is scaled only when positive. Zero and negative values are kept
bit-for-bit.

The price scale is verified from overlapping SC Data and Rithmic files and
stored per root/exchange group.

SC Data supplies records through the end of the source history. Rithmic records
sufficiently newer than the source are retained. A short timestamp guard removes
the normal overlap near the source boundary.

SCID output is written to a temporary file, flushed, checked, and then moved
into place. Existing targets receive a rolling backup.

If a source timestamp moves backward, record order is preserved. The condition
is counted and written to the run log; timestamps are not sorted or rewritten.

## Historical Daily processing

Historical Daily files use the documented fields:

```text
Date, Open, High, Low, Close, Volume, OpenInterest
```

The daily processor validates the header, field count, numeric values, and
strictly increasing dates. Prices use the same verified scale as the matching
SCID contract.

Daily files are merged by date:

1. Existing Rithmic dates are loaded.
2. SC Data replaces dates in the source history.
3. If the Rithmic target already contains the latest date present in SC Data,
   the Rithmic row is retained for that date.
4. Dates present only in the Rithmic target are retained.
5. The result is sorted by date.

The latest-date rule avoids replacing an actively updating Rithmic daily row
with a less-current Historical Daily row. When SC Data advances, the previous
date is replaced normally on the next run.

Daily output is written to a temporary file, flushed, checked, and then moved
into place. Existing `.dly` targets receive `.dly.bak` backups.

## Processed-file state

SCID and Historical Daily state are tracked independently for each contract.
Either file can update without forcing the other to be rewritten.

Saved checks include source signatures, target paths, record counts, and first
and last timestamps/dates. A deleted, truncated, or recreated target is
processed again.

## Rolling Rithmic history window

The default managed range is:

```text
current month - 5 years - 3 months
through
current month + 6 months
```

The three-month older buffer exceeds Sierra Chart's documented two-month
contract-transition range. The six-month forward buffer allows nearby future
contracts to be staged before rollover.

SC Data files outside the range remain unchanged. Bridge-managed Rithmic files
that leave the range are retired only after saved target metadata is checked.

## Windows installation

Setup supports current-user and all-users installation. Program files and
mutable per-user state are stored separately.

The C# engine is compiled with the standard Windows PowerShell 5.1 `Add-Type`
path and does not require custom compiler options, LINQ, or unsafe code.
