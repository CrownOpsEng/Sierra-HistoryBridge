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

Use the current v0.0.13 package and rerun `setup.cmd`.

The installed SCID engine is compiled with the stock Windows PowerShell 5.1
`Add-Type -Path` behavior. The converter does not require custom compiler
parameters, unsafe compilation, LINQ, or optional framework references.

If a compiler error still appears, attach `%LOCALAPPDATA%\SierraHistoryBridge\setup.log`.
