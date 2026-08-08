# Sierra History Bridge

**Version 0.0.10 — pre-stable**

Sierra History Bridge updates Rithmic-named Sierra Chart history files from
matching SC Data files.

SCID and Historical Daily files are discovered independently. A contract does
not need to have both file types.

```text
NQU26-CME.scid  ->  NQU6.CME.scid
NQU26-CME.dly   ->  NQU6.CME.dly
NQZ23-CME.dly   ->  NQZ3.CME.dly
```

The `.scid` path supplies intraday/tick history. The `.dly` path supplies
Historical Daily data used by Sierra Chart for Daily and higher-timeframe
Historical charts.

Rithmic remains the service configured in the Sierra Chart installation.
SC Data source files are not modified.

## Install

Extract the Windows release and run:

```text
setup.cmd
```

Setup supports current-user and all-users installation and can optionally
create Start Menu shortcuts.

After installation, open the Sierra Chart `Data` folder, right-click the folder
or blank space inside it, and choose:

```text
Update Sierra history from SC Data
```

## Update behavior

The application scans the Sierra Chart Data folder, applies the managed history
window, verifies the raw-price scale, and shows the update plan before changing
files.

If Sierra Chart is running when files are ready to be replaced, the application
waits for Sierra Chart to close.

### Intraday files

For `.scid` files:

- SC Data records are converted to the verified Rithmic raw-price scale.
- Trade, volume, bid/ask volume, timestamps, and Sierra control markers are
  preserved.
- Rithmic records sufficiently newer than the end of the SC Data source are
  retained.
- Output is validated before the target is replaced.

### Historical Daily files

When a matching SC Data `.dly` file exists, it is processed with the same
contract mapping and price scale.

Daily files are merged by date:

- SC Data supplies the historical rows through its latest date.
- If the Rithmic target already contains that latest date, the Rithmic row is
  retained for that date.
- Rithmic rows newer than the SC Data file are retained.
- Older Rithmic-only rows are not carried forward.
- When SC Data advances to a newer date, the previous latest date is replaced
  from SC Data on the next run.

This prevents an actively updating daily record from being replaced by a
less-current Historical Daily record while allowing completed dates to converge
to SC Data.

## Rolling Rithmic history window

Rithmic futures symbols use one year digit. Sierra Chart also limits Continuous
Futures Contract charts using single-digit-year symbols to five years.

The bridge manages:

```text
5 years history
+ 3 months older rollover buffer
+ 6 months forward-contract buffer
```

Older SC Data files remain under their two-digit-year names and are not
converted to conflicting Rithmic filenames.

## Backups and logs

Existing Rithmic files are backed up before replacement.

```text
SierraChart\Data\SCID_Bridge_Backups
SierraChart\Data\SCID_Bridge_Logs
```

The backup directory can contain both `.scid.bak` and `.dly.bak` files.

## Repair and uninstall

Run `setup.cmd` again to repair/update or uninstall. Dedicated `repair.cmd` and
`uninstall.cmd` commands are also included. Installed copies can be removed
through Windows Settings → Apps → Installed apps.

## Project status

Version 0.0.10 is pre-stable. The SCID path has been checked against real NQ SC
Data and Rithmic files. Historical Daily handling follows Sierra Chart's
documented text/CSV format and is covered by the project self-test.

This project is not affiliated with or endorsed by Sierra Chart, Rithmic,
CME Group, or their affiliates.

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


## Existing Rithmic files outside the managed range

The bridge does not remove arbitrary Rithmic history files merely because they
are outside the managed range.

Files previously recorded by the bridge can be retired after their saved
metadata is verified. Unmanaged files are left alone.

When a one-digit Rithmic filename is reused by a newer decade, processing the
new eligible SC Data contract replaces the old target history. The SCID path
preserves only genuinely newer target records. The Historical Daily path keeps
only the overlapping latest date and dates newer than the source, so old-decade
daily rows are not carried into the new contract.
