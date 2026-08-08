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
