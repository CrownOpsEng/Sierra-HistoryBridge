# Troubleshooting

## The Explorer command is missing

Run `install.cmd` again.

On Windows 11, check **Show more options** if the command is not shown in the compact context menu.

The installed command is registered for both:

```text
Directory
Directory\Background
```

under the current user's shell classes.

## The Explorer command opens the wrong folder

Run `run.cmd` once and select the correct Sierra Chart `Data` folder. The selected folder is remembered for manual launches.

When invoked from File Explorer, the folder you right-click is passed directly to the application.

## A symbol group is shown as unverified

The bridge needs at least one SC Data source and Rithmic target with overlapping timestamps for that root/exchange group.

For example:

```text
NQU26-CME.scid
NQU6.CME.scid
```

Once the scale is verified, it is remembered and can be used for other NQ/CME contracts.

## Sierra Chart is open

The application scans files while Sierra Chart is running, but it waits before replacing targets. Close all Sierra Chart instances and press Enter when prompted.

## A conversion fails

The previous Rithmic file remains available as a rolling backup under:

```text
SCID_Bridge_Backups
```

Check the latest log under:

```text
SCID_Bridge_Logs
```

and include that log when opening a bug report.

## Reset saved state

Remove:

```text
%LOCALAPPDATA%\SierraHistoryBridge\config.json
%LOCALAPPDATA%\SierraHistoryBridge\state.json
```

or run:

```text
uninstall.cmd -RemoveSettings
```

and reinstall.
