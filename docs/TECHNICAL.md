# Technical design

## SCID structure

Sierra Chart documents its intraday `.scid` format as a 56-byte header followed by 40-byte records.

Each record contains:

```text
SCDateTimeMS DateTime   8 bytes
float        Open       4 bytes
float        High       4 bytes
float        Low        4 bytes
float        Close      4 bytes
uint32       NumTrades  4 bytes
uint32       TotalVolume
uint32       BidVolume
uint32       AskVolume
```

For a single-trade/tick record, Sierra Chart documents special semantics:

- `Open` can be `0` or a special first/last sub-trade marker
- `High` is the ask price at the time of the trade
- `Low` is the bid price at the time of the trade
- `Close` is the trade price

The bridge therefore changes `Open` only when it is positive. Zero and negative control-marker values are copied bit-for-bit.

## Service-specific raw prices

The symbol filename does not live inside the SCID header. A renamed file can still be wrong because the service-specific raw price representation may differ.

The bridge does not hard-code a scale for a symbol. It selects an overlapping SC Data/Rithmic pair from the same root and exchange, samples prices across the shared time range, computes the median target/source ratio, and requires that ratio to match a supported power-of-ten scale within tolerance.

The verified scale is saved per:

```text
ROOT|EXCHANGE
```

For example:

```text
NQ|CME
```

That allows expired contracts without an existing Rithmic file to use a scale already verified from another contract in the same symbol group.

## Historical authority and live tail

For a target that already exists:

1. all records through the latest SC Data timestamp come from the converted SC source
2. target records more than two seconds newer than the SC source are preserved
3. the guard interval prevents common live/backfill duplicates at the handoff

The two-second guard is deliberately conservative. It can be made configurable in a later version if broader testing shows a reason to do so.

## Replacement sequence

For each file:

1. read the SC source
2. convert price-bearing fields in chunks
3. append the eligible newer Rithmic tail
4. flush the temporary output to disk
5. validate structure and representative records
6. atomically replace the existing target while creating a rolling backup

If the target does not yet exist, the validated temporary output is moved into place.

## Validation

The converter verifies:

- SCID magic and layout
- 56-byte header and 40-byte records
- source timestamp monotonicity
- output record count
- first timestamp
- timestamp preservation on sampled source records
- `NumTrades`, `TotalVolume`, `BidVolume`, and `AskVolume`
- bitwise preservation of non-positive `Open` control values
- expected scaled `Close` values

## State

Application state is stored under:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

`config.json` stores the selected Data folder and verified symbol-group scales.

`state.json` stores source-file signatures so unchanged expired contracts can be skipped on later runs.
