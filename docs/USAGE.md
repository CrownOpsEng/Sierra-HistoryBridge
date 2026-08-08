# Usage

## Run from File Explorer

Open the Sierra Chart `Data` folder.

Right-click blank space and choose:

```text
Update Sierra history from SC Data
```

You can also right-click the `Data` folder itself and choose the same command.

## Run directly

From the installed program folder:

```text
run.cmd
```

or use the Start Menu shortcut if one was created.

The application remembers the Sierra Chart Data folder after it has been selected.

## Normal update sequence

The application:

1. loads the SCID conversion engine
2. locates the Sierra Chart Data folder
3. scans for SC Data futures files
4. maps each source filename to the corresponding Rithmic filename
5. verifies the raw-price scale from an overlapping pair
6. skips unchanged source contracts
7. shows the update plan
8. asks for confirmation
9. waits for Sierra Chart to close before target replacement
10. converts, validates, backs up, and replaces each target

## Example

Source files:

```text
NQU26-CME.scid
NQZ26-CME.scid
```

Rithmic naming:

```text
NQU6.CME.scid
NQZ6.CME.scid
```

If `NQU26-CME.scid` and `NQU6.CME.scid` overlap, the bridge can verify the raw-price scale for the `NQ|CME` symbol group. That verified scale can then be used for other NQ/CME contracts.

## Dry run

From PowerShell:

```powershell
.pp\SierraHistoryBridge.ps1 -DryRun -Interactive
```

A dry run scans and displays the update plan without changing files.

## Force reprocessing

```powershell
.pp\SierraHistoryBridge.ps1 -Force -Interactive
```

This ignores the processed-file state and reprocesses eligible source files.

## Backups and logs

Existing Rithmic targets receive a rolling backup under:

```text
SCID_Bridge_Backups
```

Each bridge run writes a log under:

```text
SCID_Bridge_Logs
```


## Timestamp warnings

If an SC Data source contains one or more timestamps that move backward, the
bridge prints a warning and records the details in the run log. Conversion
continues and the original record sequence is preserved.

The bridge does not sort or rewrite those source timestamps.


## Deleted or recreated target files

The bridge does not treat a file as valid merely because the filename exists.

Sierra Chart can create a header-only `.scid` placeholder when a symbol is
opened. The bridge identifies a zero-record target as a placeholder and shows:

```text
replace ... (header-only placeholder: 56 bytes, 0 records)
```

Processed-file state also stores minimum target metadata. If a converted target
is deleted, truncated, or later recreated as a placeholder, the source is
automatically placed back in the update plan even when the SC Data source file
itself has not changed.


## Console status display

Each file uses one live status line. The same line is updated as the file moves
through:

```text
CONVERT -> FLUSHING -> VALIDATE -> REPLACE -> VERIFY
```

The final line is retained as a compact result, for example:

```text
[1/5] NQH26-CME -> NQH6.CME | OK | 30.84M rec | 1.15 GB | 13.8s
```

A timestamp anomaly is shown on the same final line as a warning. Full anomaly
details and per-stage timings remain in the run log.

This keeps the console useful as a reviewable run report while still showing
live progress during large conversions.
