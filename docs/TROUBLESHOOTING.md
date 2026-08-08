# Troubleshooting

## Explorer says "Application not found"

Re-run:

```text
repair.cmd
```

or:

```text
setup.cmd
```

and choose **Repair / update**.

The repair process rewrites the Explorer integration to point directly to the installed Windows PowerShell executable and installed bridge script.

## The Explorer command is missing

Run a repair.

On Windows 11, also check **Show more options** in the context menu.

## The wrong Sierra Chart folder is selected

Run the bridge directly with `run.cmd` and enter the correct Sierra Chart `Data` folder when prompted.

The selected folder is remembered.

## A symbol group is "unverified"

At least one SC Data source and Rithmic target in that root/exchange group need overlapping timestamps.

Example:

```text
NQU26-CME.scid
NQU6.CME.scid
```

After a scale is verified, it is remembered for the rest of that symbol group.

## Sierra Chart is open

The bridge can scan while Sierra Chart is running, but target files are not replaced while Sierra Chart is open.

Close every Sierra Chart instance and continue when prompted.

## A conversion fails

Check:

```text
SierraChart\Data\SCID_Bridge_Logs
```

The previous Rithmic target should remain available as:

```text
SierraChart\Data\SCID_Bridge_Backups\<target>.bak
```

## Setup, repair, or uninstall fails

Check:

```text
%LOCALAPPDATA%\SierraHistoryBridge\setup.log
```

For an all-users installation, rerun setup and approve the administrator prompt.

## Reset remembered settings

Uninstall the application and choose to remove saved application settings.

You can also manually remove:

```text
%LOCALAPPDATA%\SierraHistoryBridge\config.json
%LOCALAPPDATA%\SierraHistoryBridge\state.json
```




## Setup reports a C# compiler or assembly-reference error

Use the current v0.0.24 package and rerun `setup.cmd`.

The installed SCID engine is compiled with the stock Windows PowerShell 5.1
`Add-Type -Path` behavior. The converter does not require custom compiler
parameters, unsafe compilation, LINQ, or optional framework references.

If a compiler error still appears, attach `%LOCALAPPDATA%\SierraHistoryBridge\setup.log`.


## Zero-volume warnings in very early NQ Daily history

Do not edit these rows merely to remove Sierra Chart warnings. The bridge treats
zero-volume Daily rows as source-data quality information and preserves the
original file exactly.

For continuous back-adjusted history reaching the beginning of E-mini
Nasdaq-100 trading, Sierra Chart can report zero-volume or missing-date
conditions because the required early Daily history is incomplete. Reducing the
continuous chart's loaded history avoids using those dates, but keeping the
full historical files is valid when the limitation is understood.


## CLEANUP WARNING: folder is in use

If this occurs while restoring from File Explorer, older builds could have
started PowerShell with its working directory inside the selected archive's
year folder. The bridge was therefore the process preventing its own cleanup.

Current builds move both PowerShell's provider location and the process current
directory to the Sierra Data base before archive/restore and again before
pruning. Simply having the folder visible in File Explorer normally does not
require closing Explorer.


## Folder remains locked after restore

If immediate cleanup reports `CLEANUP DEFERRED`, press Enter to close the bridge
window. A detached helper then retries for up to 30 seconds.

Check the printed `cleanup-*.log` path. If it says `REMOVED`, the lock was tied
to the original process/context-menu lifetime. If it says `FAILED after parent
exit`, another process still owns the directory; that log is the useful next
diagnostic artifact.

Archive, Restore, and Storage now also have their own timestamped operation logs
in the configured Logs folder.


## Deferred cleanup still reports FAILED

The isolated helper now starts without inheriting the parent/context-menu
handle set. If `cleanup-*.log` still says `FAILED after parent exit`, the lock
is genuinely external to both bridge processes for the full retry window.

The unresolved path is preserved in `pending-cleanup.json` and retried on the
next utility run. At that point a Windows handle-owner diagnostic (Resource
Monitor, Process Explorer, or equivalent) is appropriate; the bridge should not
terminate unrelated processes just to remove an empty folder.
