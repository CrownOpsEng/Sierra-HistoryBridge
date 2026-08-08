# Installation and maintenance

## Recommended installation

Run:

```text
setup.cmd
```

For most users, choose:

```text
Current user
```

This installs the program under the user's local Programs directory and avoids administrator elevation.

Choose **All users** only when the application should be installed for every Windows user on the machine. That installation goes under `Program Files` and requires administrator approval.

## Start Menu shortcuts

Setup asks whether to create a Start Menu / All apps folder.

When enabled, the folder contains:

- **Sierra History Bridge**
- **Sierra History Bridge Documentation**
- **Repair Sierra History Bridge**
- **Uninstall Sierra History Bridge**

The shortcuts are optional. File Explorer integration and the Windows Installed apps entry are created regardless.

## File Explorer integration

Setup registers:

```text
Update Sierra history from SC Data
```

for:

- a right-click on a folder
- a right-click on blank space inside a folder

On Windows 11, the command may appear under **Show more options**, depending on the Explorer configuration.

The Explorer entry calls the installed PowerShell application directly with the selected folder path.

## Windows Installed apps entry

Setup registers Sierra History Bridge with Windows so it appears in:

```text
Settings → Apps → Installed apps
```

The registration includes:

- display name and version
- publisher
- install location
- uninstall command
- quiet uninstall command
- repair/modify command for Windows interfaces that honor it
- estimated installed size

## Repair

Repair recopies the application and documentation from the clean repair payload stored under:

```text
<install folder>\setup\payload.zip
```

It then validates the PowerShell application, compiles the SCID conversion engine, rebuilds Explorer integration, recreates Start Menu shortcuts according to the saved preference, and refreshes the Installed apps registration.

Ways to repair:

```text
repair.cmd
```

or rerun:

```text
setup.cmd
```

and choose **Repair / update**.

If Start Menu shortcuts were enabled, a Repair shortcut is also available there.

## Uninstall

Use any of:

```text
uninstall.cmd
```

the Start Menu uninstall shortcut, or:

```text
Settings → Apps → Installed apps → Sierra History Bridge → Uninstall
```

Uninstall removes:

- installed program files
- Explorer context-menu entries
- Start Menu shortcuts
- Installed apps registration

It asks whether to remove saved application settings/state.

The following are intentionally left alone:

```text
SierraChart\Data\SCID_Bridge_Backups
SierraChart\Data\SCID_Bridge_Logs
```

They are recovery/history files inside the user's Sierra Chart data directory.

## Storage layout

### Program files

Current user:

```text
%LOCALAPPDATA%\Programs\Sierra History Bridge
```

All users:

```text
%ProgramFiles%\Sierra History Bridge
```

### Mutable per-user state

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

This contains:

- `config.json` — remembered Sierra Chart Data folder and verified symbol-group scales
- `state.json` — processed-source signatures
- `setup.log` — setup/repair/uninstall diagnostics

### Sierra Chart-generated bridge data

Inside the selected Sierra Chart Data directory:

```text
SCID_Bridge_Backups
SCID_Bridge_Logs
```
