# Usage

## Run

Open the Sierra Chart `Data` folder. Right-click blank space or the folder and
choose:

```text
Update Sierra history from SC Data
```

The bridge can also be run with `run.cmd`.

## Update sequence

A normal run:

1. locates the Sierra Chart Data folder
2. scans SC Data futures contracts
3. applies the rolling Rithmic history window
4. verifies the raw-price scale
5. checks eligible `.scid` and `.dly` sources independently
6. shows the update plan
7. waits for Sierra Chart to close
8. updates and validates the required files
9. saves state and writes the run log

A contract can require an SCID update, a DLY update, both, or neither.
Historical Daily files are included even when the matching SCID source is not
present.

```text
UPDATE  NQU26-CME -> NQU6.CME | SCID current | DLY update
UPDATE  NQZ26-CME -> NQZ6.CME | SCID update | DLY create
```

## Status display

Each contract uses one live status line. The retained result contains exact
record totals.

```text
[1/2] NQU26-CME -> NQU6.CME | OK | SCID src=19,571,469 -> out=19,571,469 | DLY src=349 applied=348 kept=1 -> out=349 | 9.8s
```

For DLY results:

- `src`: SC Data daily records
- `applied`: source records written into the result
- `kept`: Rithmic target records retained
- `out`: final records

## Historical Daily latest-date rule

If the Rithmic `.dly` target contains the same date as the latest SC Data daily
record, the Rithmic row is retained for that date.

On a later run, when SC Data contains a newer date, the previous date becomes
normal historical data and is replaced from SC Data.

Rithmic dates newer than the latest SC Data date are retained. Older target-only dates are not carried forward.


## Updating while Sierra Chart is running

Historical updates do not require Sierra Chart to be closed.

If the update plan contains a recent SCID target, the bridge treats it as a
possible live file and asks how to proceed:

```text
1. Update all - disconnect Sierra Chart and close affected chartbooks
2. Update all - close Sierra Chart
3. Skip live SCID updates and continue with remaining updates
4. Cancel
```

Option 3 is shown only when there is other work to perform.

For option 1, use **File > Disconnect** and close the chartbooks using the live
symbol. **File > Close All Chartbooks** is the simplest choice when several
charts use that symbol.

For historical-only updates, Sierra Chart can remain open. If an affected chart
was already open, use **Chart > Reload and Recalculate** after the update.

If Windows reports that a historical target is in use, close the affected
chart/chartbook and run the bridge again.

When `-Yes` is used while Sierra Chart is running, live SCID updates are skipped
when other work is available. The switch does not bypass the live-file safety
check.

## Dry run

```powershell
.\app\SierraHistoryBridge.ps1 -DryRun -Interactive
```

## Force reprocessing

```powershell
.\app\SierraHistoryBridge.ps1 -Force -Interactive
```

## Rolling history window

```text
current month - 5 years - 3 months
through
current month + 6 months
```

Older SC Data contracts remain under their two-digit-year names.

## Backups and logs

```text
SCID_Bridge_Backups
SCID_Bridge_Logs
```

The backup directory can contain `.scid.bak` and `.dly.bak` files.


## Files outside the managed range

The application does not remove Rithmic files it did not create or previously
record. Unused chart-data files can remain in the Data folder.

Bridge-managed files can be retired after their saved metadata is verified.
This is housekeeping rather than a requirement for chart loading.

A newer eligible decade can reuse the same one-digit Rithmic filename. In that
case the new conversion replaces the old contract data rather than merging old
decade history into the new file.


## Independent SCID and DLY updates

SCID and Historical Daily files are checked independently. A changed SCID source
does not cause the matching `.dly` file to be rewritten.

The Daily source is identified by its file content rather than its Windows
modification time. If an existing target already matches the expected Daily
result, the plan reports `DLY current` even when the source file timestamp has
changed.


## Historical SCID replacement

Historical SCID updates should normally show:

```text
SCID replace src=33,741,xxx -> out=33,741,xxx
```

The source and output record counts are identical. Their file sizes are also
identical.

If an old contract is still downloading, the plan can show:

```text
SCID deferred - SCID ends 2021-09-30; Daily history ends 2021-12-17
```

or the run can defer it if the source changes during conversion. The existing
Rithmic target is left untouched.

Only a live-sensitive contract can show `SCID live-merge`, and the log records
the source total, source records used, preserved Rithmic records, and the
handoff timestamp and number of matching trade seconds used to verify it.

## Preflight data comparison

Existing Rithmic SCID data is used as an independent validation source before it
is replaced. The bridge shows a preflight line similar to:

```text
NQZ21-CME -> NQZ1.CME | STRONG | coverage=99.987% | volume/sec=99.562% | last-price=99.852% | aggregate-volume-diff=0.000153%
```

If the SC Data source is incomplete or the feeds disagree beyond the normal
comparison thresholds, the bridge stops for that contract and asks for a
decision before any history file is changed.

The safe default is always to keep the existing target and defer the SCID
update. A temporary SC Data/Rithmic merge is offered only when the overlap is
strongly validated and Rithmic contributes later coverage without an earlier
coverage segment that would be lost.

The first time an existing Rithmic SCID is replaced, the bridge preserves an
immutable compressed Rithmic baseline when the target has not previously
been managed. Future comparisons read that `.gz` baseline directly without
extracting it. The normal raw `.bak` file
continues to hold the immediately previous target and may change on later runs.
