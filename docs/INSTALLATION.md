# Installation

## Requirements

- Windows
- Windows PowerShell 5.1
- Sierra Chart installation
- writable Sierra Data folder
- enough free space for verified temporary output

## Application paths

Default program installation:

```text
C:\Program Files\Sierra History Bridge
```

Current-user application state:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

The space in the Program Files folder is intentional and follows normal Windows
application naming. The compact `SierraHistoryBridge` identifier is used for
LocalAppData and bridge-owned filesystem namespaces.

## Sierra instance selection

Sierra History Bridge treats the Sierra installation and Sierra Data folder as
separate paths.

Setup/Repair resolves:

```text
SierraPath
DataPath
```

A Sierra installation path is validated as a Sierra Chart installation.

The default Data folder is:

```text
<SierraPath>\Data
```

but the user can select a different Data folder to match Sierra Chart's actual
configuration.

This supports:

- multiple independent Sierra installations
- relocated Data folders
- Data stored on another drive

## Derived paths

Unless explicitly customized where allowed:

```text
Storage = <DataPath>\HistoryBridge
Temp    = <DataPath>\HistoryBridgeTemp
Logs    = <SierraPath>\Logs\HistoryBridge
```

`Temp` is derived from DataPath and is not independently configurable because
same-volume transaction staging is required for safe replacement behavior.

`Storage` and `Logs` can be customized.

## Lazy directories

Setup does not create empty persistent history categories or
`HistoryBridgeTemp`.

Folders are created on first use:

```text
HistoryBridge\Archive
HistoryBridge\Baselines
HistoryBridge\Rollbacks
HistoryBridge\RestoreConflicts
```

and removed when empty where safe.

`Logs\HistoryBridge` exists because Setup itself writes a log.

## Repair

Repair validates the exact package before replacing installed program files:

1. PowerShell parser validation
2. C# `Add-Type` compilation
3. only then application replacement

If the configured installation still uses the immediately preceding bridge
folder arrangement, Repair offers to relocate bridge-owned files into the
current `HistoryBridge` layout.

Relocation is conservative:

- recognized owned files are moved
- composite filename separators become `--`
- old baseline candidates begin as `UN` and must be re-authenticated
- unrecognized material is not deleted
- Repair stops if an unauthenticated baseline cannot be preserved safely

## Explorer integration

Folder commands use the Single selection model:

- Update History
- Storage Report

File commands use the Windows Player multi-select model:

- Archive SC Data
- Restore SC Data
- Rollback Rithmic

File selections are collected through:

```text
%TEMP%\SierraHistoryBridge\Explorer
```

before one visible operation is started.

On Windows 11 these commands may appear under **Show more options**.

## Uninstall

Use Windows **Settings > Apps** or the installed uninstall command.

Uninstall removes application files, Explorer integration, Start Menu entries
and Installed Apps registration.

Persistent Sierra history/archive material is not automatically deleted.
