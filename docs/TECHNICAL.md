# Technical design

## Data files

Sierra Chart uses separate files for intraday and Historical Daily data:

```text
.scid   intraday data
.dly    Historical Daily data
```

SCID and Historical Daily sources are discovered independently and joined by
futures root, delivery month, two-digit year, and exchange. Either source type
can exist without the other.

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

1. SC Data supplies the output through its latest date.
2. If the Rithmic target contains the same latest date, that target row is
   retained for that date.
3. Target rows strictly newer than the latest SC Data date are retained.
4. Older target-only rows are not retained.
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


## Independent source discovery

The scanner builds the managed contract set from both SC Data naming forms:

```text
<root><month><YY>-<exchange>.scid
<root><month><YY>-<exchange>.dly
```

The history window is applied to the combined contract set. Historical Daily
contracts are therefore included even when intraday history has not been
downloaded for the same delivery month.

Price scale can be proven from either an overlapping SCID pair or an overlapping
Historical Daily pair. A previously proven scale for the same root/exchange can
also be reused.

## Old Rithmic files

Unmanaged Rithmic files are not removed.

When a one-digit Rithmic symbol is reused by a newer decade, the eligible source
replaces the old target content. SCID conversion keeps only target records newer
than the source boundary. Historical Daily processing keeps only the latest
overlapping date and target dates newer than the source boundary.


## Live-file handling

Sierra Chart opens SCID files with shared read/write access and can buffer
streaming data before flushing it to disk. Replacing a file that can still
receive streaming writes therefore requires a different policy from replacing
an expired historical contract.

A pending SCID update is classified as live-sensitive when any of the following
is true:

- the SC Data source ends within the last seven days
- the existing Rithmic target ends within the last seven days
- the Rithmic target was modified within the last ten minutes

The seven-day interval is a safety margin for weekends and exchange holidays.
It is not used to decide contract rollover or trading eligibility.

When Sierra Chart is running, live-sensitive SCID replacement requires either:

- disconnecting the data feed and closing the affected chartbooks, or
- closing Sierra Chart

The user can instead skip those SCID files and continue with independent
Historical Daily or expired-contract updates.

Historical files are attempted while Sierra Chart remains open. If an open file
handle prevents replacement, the operation fails without replacing the target
and the user can close the affected chart/chartbook and retry.

After a successful historical replacement, **Chart > Reload and Recalculate**
causes an already-open chart to reread its chart-data file.



## Historical Daily change detection

Historical Daily and SCID change detection are independent.

Because `.dly` files are small, the source Daily file uses a SHA-256 content
signature. File modification time is not used to decide whether a Daily target
needs to be rewritten.

If saved state is missing or comes from an older bridge version, the bridge
performs a semantic comparison between the SC Data source and the Rithmic
target using the verified price scale and the normal Daily merge rules. If the
target already represents the expected result, the state is refreshed without
rewriting the `.dly` file.

This prevents an SCID download, file copy, or timestamp-only change from causing
an unrelated Historical Daily update.


## SCID source authority and live handoff

Historical contracts use source-only replacement:

```text
SC Data source -> scale conversion -> Rithmic-named target
```

No target records are retained. Record count and file length must match the
source exactly.

A live-sensitive contract can preserve a genuinely newer target segment. Raw
microsecond timestamps are not compared across feeds. The target must extend
into a later whole second, or contain greater total volume when both feeds end
in the same second. The trailing overlap must then contain at least three
consecutive active seconds with matching total, bid, and ask volume plus scaled
last price.

```text
SC Data: timestamps < handoff second
Rithmic: timestamps >= handoff second
```

The selected second is a strict half-open boundary. If the boundary cannot be
verified, or either side is non-monotonic, the target is not changed.

Before replacement, the bridge re-reads source metadata and modification time.
For a live merge it does the same for the target. Any change causes the
temporary output to be discarded.

Historical sources are also deferred when a matching Historical Daily source
shows that the SCID file has not yet reached the end of the contract, or when
the SCID source was modified within the last five seconds.

## SCID preflight validation

When both an SC Data source and an existing Rithmic SCID target are available,
the bridge compares them before any history file is replaced.

The comparison is performed over the complete overlapping time range at
one-second resolution. It records:

- structural validity and record alignment
- source and target timestamp ordering
- first and last timestamps and record counts
- overlap coverage in seconds
- exact per-second total-volume agreement
- exact per-second bid-volume and ask-volume agreement
- exact last-price agreement after the verified raw-price scale is applied
- aggregate overlap-volume difference
- the proportion of records containing bid/ask spread information

A strong comparison currently requires at least 100 common seconds, at least
99% common-second coverage, at least 98% exact per-second volume agreement, at
least 99% exact last-price agreement, and no more than 0.5% aggregate overlap
volume difference. These thresholds classify cross-feed consistency; a failure
does not by itself prove that either feed is corrupt.

Structural faults, out-of-order source records, incomplete coverage, or weak
cross-feed agreement are surfaced before conversion. Ambiguous cases require a
user decision. With unattended `-Yes` operation, ambiguous SCID work is deferred
rather than forced.

### Incomplete historical sources

If Historical Daily coverage or the existing Rithmic target shows that an SCID
source ends early, the bridge does not silently replace the more complete
Rithmic file.

If the overlapping data validates strongly and the Rithmic target only extends
later than the source, the interactive choices are:

1. keep the Rithmic target and defer the SCID update (default)
2. create a temporary merge using verified SC Data for the overlap and Rithmic
   only beyond the source boundary
3. cancel the run

A temporary merge is deliberately not marked current in bridge state. A later
run re-evaluates the contract and rebuilds it when the SC Data source is
complete.

The bridge also rechecks source and target metadata after validation and after
conversion. If either file changes during either operation, the temporary work
is discarded and the SCID update is deferred.

### Independent Rithmic baseline

On the first bridge replacement of an existing Rithmic SCID target, the bridge
can preserve an immutable validation copy in `SCID_Bridge_Backups` using the
suffix `<SC-source>__<Rithmic-target>.rithmic-baseline.bak`. Later preflight runs prefer this baseline over a
target that has already been modified by the bridge, avoiding circular
validation against the bridge's own prior output.

The existing `.bak` file remains the rolling immediately-previous target used
for ordinary recovery. The immutable Rithmic baseline is not overwritten.

For installations that were already processed by an older bridge version and
do not have an immutable baseline, the current target can still be compared but
is labeled `managed target`; it is not presented as independent Rithmic
evidence.
