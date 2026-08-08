# Sierra History Bridge

**Current version: v0.0.1 — experimental**

Sierra History Bridge is a Windows utility for Sierra Chart that uses **SC Data historical intraday files** to update the corresponding **Rithmic-named `.scid` files**. This lets a Rithmic-connected Sierra Chart installation keep its normal symbols and live feed while using richer SC Data records for the historical portion of the file.

Example:

```text
NQU26-CME.scid  ->  NQU6.CME.scid
```

For an existing Rithmic file, SC Data becomes authoritative through the latest timestamp available in the SC source. Rithmic records that are genuinely newer than that source are preserved at the end of the output file.

## Why this exists

A Sierra Chart installation connected to Rithmic normally uses Rithmic symbol filenames such as `NQU6.CME.scid`. Historical data downloaded through SC Data uses a different symbol filename such as `NQU26-CME.scid`.

Renaming the file is not enough because the raw price representation can differ between services. Sierra History Bridge verifies the raw-price scale from an overlapping SC Data/Rithmic pair, converts the SC Data records to the corresponding Rithmic convention, validates the result, and updates the Rithmic-named file.

## Quick start

1. Download or clone the repository.
2. Run **`install.cmd`**.
3. Open the Sierra Chart `Data` folder in File Explorer.
4. Right-click the folder or blank space inside it.
5. Choose **Update Sierra history from SC Data**.
6. Review the update plan and confirm it.
7. Close Sierra Chart when prompted so the files can be replaced safely.

You can also run **`run.cmd`** directly. The application remembers the Sierra Chart Data folder after the first manual selection.

## What it preserves

For converted SCID records, the bridge preserves:

- timestamps
- number of trades
- total volume
- bid volume
- ask volume
- Sierra single-trade and CME unbundled-trade markers in the `Open` field

It converts the price-bearing fields to the verified Rithmic raw-price scale.

When an existing Rithmic target contains records newer than the SC Data source, those newer records are appended after the converted historical section. A two-second boundary guard is used to avoid retaining typical live/backfill overlap at the handoff.

## Safety

Before replacing an existing target, the bridge:

- writes the converted output to a temporary file
- validates record count, timestamps, price scaling, volume fields, and special `Open` markers
- creates a rolling backup of the previous Rithmic target
- performs the final replacement only after validation succeeds

Backups are stored in:

```text
SierraChart\Data\SCID_Bridge_Backups
```

Logs are stored in:

```text
SierraChart\Data\SCID_Bridge_Logs
```

The SC Data source files are read as the source of truth and are not rewritten.

## Supported source naming

v0.0.1 recognizes Sierra Chart futures filenames in this form:

```text
<root><month><2-digit-year>-<exchange>.scid
```

Examples:

```text
NQU26-CME.scid
MNQU26-CME.scid
ESH26-CME.scid
```

The corresponding Rithmic target uses the final year digit and a dot before the exchange:

```text
NQU6.CME.scid
MNQU6.CME.scid
ESH6.CME.scid
```

A symbol group must have at least one overlapping SC Data/Rithmic pair so the bridge can verify its raw-price conversion scale. Once verified, that scale is remembered for other contracts in the same root/exchange group.

## Project status

This project is starting at **v0.0.1** and is intentionally pre-stable. The initial implementation has been developed and checked against real NQ SC Data and Rithmic SCID files, but it should be treated as experimental software that modifies local market-data files.

This project is not affiliated with or endorsed by Sierra Chart, Rithmic, CME Group, or their affiliates.

## Documentation

- [Usage guide](docs/USAGE.md)
- [Technical design](docs/TECHNICAL.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Publishing to GitHub](docs/PUBLISHING.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE).
