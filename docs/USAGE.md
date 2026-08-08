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
