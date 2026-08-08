# Sierra History Bridge

**Version 0.0.2 — experimental / pre-stable**

Sierra History Bridge updates Sierra Chart **Rithmic-named intraday files** with **SC Data historical records**, while preserving Rithmic records that are genuinely newer than the SC Data source.

Example:

```text
NQU26-CME.scid  ->  NQU6.CME.scid
```

The goal is a single Sierra Chart installation that can continue using Rithmic for live data and order routing while retaining richer SC Data records for historical analysis.

## Install

Download the Windows release, extract it, and run:

```text
setup.cmd
```

Setup asks:

1. whether to install for the **current user** or **all users**
2. whether to create **Start Menu / All apps shortcuts**

Current-user installation is recommended for most users and does not require administrator access.

After installation, open the Sierra Chart `Data` folder, right-click the folder or blank space inside it, and choose:

```text
Update Sierra history from SC Data
```

## Everyday use

The bridge scans the selected Sierra Chart Data folder for SC Data futures files such as:

```text
NQU26-CME.scid
NQZ26-CME.scid
ESH26-CME.scid
```

It maps them to the corresponding Rithmic filenames, verifies the raw-price scale from an overlapping SC Data/Rithmic pair, shows an update plan, and asks for confirmation.

If Sierra Chart is open when replacement is about to occur, the bridge waits for it to be closed.

Unchanged historical contracts are skipped on later runs.

## Repair and uninstall

You can maintain the installation in several ways:

- run `setup.cmd` again and choose **Repair / update** or **Uninstall**
- run `repair.cmd`
- run `uninstall.cmd`
- use the optional Start Menu shortcuts
- remove the application through **Windows Settings → Apps → Installed apps**

A clean repair payload is stored with the installed setup files so the application files can be restored without the original downloaded archive.

## Installation locations

Sierra History Bridge separates program files from mutable user data.

### Current-user installation

Program files:

```text
%LOCALAPPDATA%\Programs\Sierra History Bridge
```

Application settings/state:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

Start Menu shortcuts, when selected:

```text
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Sierra History Bridge
```

### All-users installation

Program files:

```text
%ProgramFiles%\Sierra History Bridge
```

Each user's settings/state remain under that user's:

```text
%LOCALAPPDATA%\SierraHistoryBridge
```

All-users Start Menu shortcuts, when selected:

```text
%ProgramData%\Microsoft\Windows\Start Menu\Programs\Sierra History Bridge
```

## Installed files

The installed program folder contains the application, documentation, setup and maintenance tools:

```text
Sierra History Bridge/
├── app/
│   ├── SierraHistoryBridge.ps1
│   └── ScidBridge.cs
├── docs/
├── setup/
│   ├── Setup.ps1
│   └── payload.zip
├── README.md
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── VERSION
├── setup.cmd
├── run.cmd
├── repair.cmd
└── uninstall.cmd
```

The original release archive is not required after installation.

## Data handling and recovery

SC Data source `.scid` files are not rewritten.

For an existing Rithmic target, the bridge writes a converted temporary file, validates it, creates a rolling backup of the previous target, and then replaces the target.

Backups:

```text
SierraChart\Data\SCID_Bridge_Backups
```

Run logs:

```text
SierraChart\Data\SCID_Bridge_Logs
```

These Sierra Data-folder backups and logs are left in place when the application is uninstalled.

## What the converter preserves

The bridge preserves:

- timestamps
- number of trades
- total volume
- bid volume
- ask volume
- Sierra single-trade and CME unbundled-trade control markers in the `Open` field

It converts price-bearing fields to the verified Rithmic raw-price convention.

When an existing Rithmic file contains records newer than the SC Data source, those records are preserved after the converted historical section. A short handoff guard is used to avoid retaining typical live/backfill overlap.

## Project status

This is the first Git-tracked pre-stable release. The converter has been developed and checked against real NQ SC Data and Rithmic SCID files, but software that modifies local market-data files should still be treated carefully until it has broader testing.

This project is not affiliated with or endorsed by Sierra Chart, Rithmic, CME Group, or their affiliates.

## Documentation

- [Installation and maintenance](docs/INSTALLATION.md)
- [Usage](docs/USAGE.md)
- [Technical design](docs/TECHNICAL.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Development](docs/DEVELOPMENT.md)
- [Publishing](docs/PUBLISHING.md)
- [Contributing](CONTRIBUTING.md)
- [Security and data integrity](SECURITY.md)

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE).
