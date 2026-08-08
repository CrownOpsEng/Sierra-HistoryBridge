# Usage

## Install the File Explorer command

Run:

```text
install.cmd
```

The installer copies the application into:

```text
%LOCALAPPDATA%\SierraHistoryBridge\app
```

and adds this File Explorer command:

```text
Update Sierra history from SC Data
```

You can invoke it by right-clicking:

- the Sierra Chart `Data` folder, or
- blank space inside the `Data` folder

On Windows 11, legacy shell commands may appear under **Show more options** depending on Explorer configuration.

## Run without installing the Explorer command

Run:

```text
run.cmd
```

If no folder is supplied, Sierra History Bridge checks the remembered folder and common Sierra Chart locations. It shows the selected folder before scanning.

You can also pass a folder directly:

```text
run.cmd "C:\SierraChart\Data"
```

## Normal update flow

The application:

1. loads the SCID conversion engine
2. locates the Sierra Chart Data folder
3. finds SC Data futures files
4. maps each source to its Rithmic filename
5. verifies the raw-price scale from an overlapping source/target pair
6. skips source files that have not changed since the last successful run
7. displays the files that are ready to update
8. waits for confirmation
9. waits for Sierra Chart to close if it is running
10. converts, validates, backs up, and replaces each target

## Example

If the Data folder contains:

```text
NQU26-CME.scid
NQZ26-CME.scid
NQU6.CME.scid
```

and the overlapping `NQU26-CME.scid` / `NQU6.CME.scid` pair verifies the NQ/CME scale, the bridge can update:

```text
NQU6.CME.scid
```

and create:

```text
NQZ6.CME.scid
```

from the SC Data sources.

## Force a reprocess

From a command prompt in the repository:

```text
run.cmd -Force
```

## Preview without changing files

```text
run.cmd -DryRun
```

## Uninstall the File Explorer command

Run:

```text
uninstall.cmd
```

The remembered Data folder, verified scales, and processed-file state remain in:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

To remove those settings too:

```text
uninstall.cmd -RemoveSettings
```
