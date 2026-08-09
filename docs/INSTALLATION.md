# Installation

## Requirements

- Windows
- Sierra Chart
- Windows PowerShell 5.1
- a Sierra Chart Data folder containing SC Data and/or Rithmic history files

## Install

Extract the release and run:

```text
setup.cmd
```

Choose:

- current user — installs under `%LOCALAPPDATA%\Programs\Sierra History Bridge`
- all users — installs under `%ProgramFiles%\Sierra History Bridge`

Setup can create Start Menu shortcuts and registers the application in Windows
Installed apps.

## Configured folders

Setup records four locations:

- **Data** — Sierra Chart Data folder
- **Archive** — persistent compressed archives
- **Recovery** — temporary replacement/recovery staging
- **Logs** — operation logs

Default storage locations are under the Sierra Chart Data folder:

```text
SCID_Bridge_Archive
SCID_Bridge_Backups
SCID_Bridge_Logs
```

Archive, Recovery, and Logs may be placed on other drives.

## Explorer integration

The installer creates scoped Explorer commands.

Configured Sierra Data folder:

- **Update History**
- **Storage Report**

SC Data `.scid` and `.dly` files directly in the Data folder:

- **Archive SC Data**

Verified `.gz` files in `SCID_Bridge_Archive\SC_Data`:

- **Restore SC Data**

Verified `.gz` files in `Rithmic_Baselines` and `Rollbacks`:

- **Rollback Rithmic**

On Windows 11 these entries may appear under **Show more options**.


### Multi-select behavior

File verbs are registered with the Windows `Player` multi-select model and feed
their selections into one bridge batch.

Supported Explorer batch targets:

- **Archive SC Data** — multiple SC Data `.scid` / `.dly` files
- **Restore SC Data** — multiple `SC_Data` `.gz` archives
- **Rollback Rithmic** — multiple Rithmic backup `.gz` files

Folder commands (**Update History** and **Storage Report**) use the `Single`
selection model.

The legacy Windows `Player` model supports up to 100 selected items.

## Start Menu

When enabled, the Start Menu folder contains:

- Sierra History Bridge
- Archive SC Data
- Restore SC Data
- Rollback Rithmic
- Storage Report
- Sierra History Bridge Documentation
- Repair Sierra History Bridge
- Uninstall Sierra History Bridge

## Repair

Run:

```text
repair.cmd
```

or run `setup.cmd` and choose Repair.

Repair reinstalls the packaged application files and Explorer/Start Menu
integration while preserving current settings and state.

## Uninstall

Use Windows Settings → Apps → Installed apps, run `uninstall.cmd`, or use the
Start Menu shortcut.

Uninstall can remove the saved application settings/state. Archive, Recovery,
and Log folders are not deleted automatically.
