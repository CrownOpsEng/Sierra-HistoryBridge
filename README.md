# Sierra History Bridge

**Version 0.0.31**

Sierra History Bridge maintains Rithmic-named Sierra Chart history files from
matching Sierra Chart SC Data files.

It is designed for a Sierra Chart installation that remains configured for
Rithmic while using SC Data as the historical source.

```text
NQU26-CME.scid  ->  NQU6.CME.scid
NQU26-CME.dly   ->  NQU6.CME.dly
```

SCID and Historical Daily files are discovered and processed independently.

## Main functions

- update Rithmic SCID history from SC Data
- update Rithmic Historical Daily files from SC Data
- preserve genuinely newer Rithmic records for live-sensitive SCID files
- validate overlapping SC Data and Rithmic history before replacement
- archive and restore SC Data files
- retain verified Rithmic baselines and rollback copies
- roll a Rithmic target back to a verified backup
- report logical and allocated disk usage
- use Windows file compression for generated/restored market-data targets
- keep archive, recovery, and log locations configurable

## Installation

Extract the release and run:

```text
setup.cmd
```

Setup supports current-user and all-users installation, optional Start Menu
shortcuts, repair, and uninstall.

The configured Sierra Chart Data folder receives these Explorer commands:

- **Update History**
- **Storage Report**

Relevant files receive:

- SC Data `.scid` / `.dly` → **Archive SC Data**
- `SC_Data` `.gz` archives → **Restore SC Data**
- `Rithmic_Baselines` / `Rollbacks` `.gz` backups → **Rollback Rithmic**

The integration is scoped to the configured Sierra folders. It does not add a
global Explorer background menu.

## Update policy

The managed Rithmic history range is:

```text
5 years usable history
+ 3 months rollover buffer
+ 6 months forward-contract buffer
```

This keeps the one-digit Rithmic symbol namespace inside a single decade.

Historical SCID contracts are rebuilt from SC Data. A live-sensitive contract
can preserve a demonstrably newer or more complete Rithmic tail after at least
three matching active seconds verify a strict whole-second handoff. Source and
target files are checked again before publication.

Historical Daily files are merged by date. SC Data owns completed historical
dates. A current Rithmic row for the latest SC Data date can be retained, and
Rithmic dates newer than the SC Data source are preserved.

## Validation

Before replacing an existing historical Rithmic SCID, the bridge can compare
the overlapping feeds for:

- timestamp coverage and ordering
- volume by second
- bid/ask volume
- last price after scale conversion
- aggregate volume
- SCID data richness

Lengthy full-file validation is optional in interactive runs. Skipping it
defers the affected SCID files; it does not bypass validation.

The first independent Rithmic file used for cross-feed validation can be kept
as a compressed baseline.

## Archive layout

Persistent market-data archives are flat within their category:

```text
SCID_Bridge_Archive\
  SC_Data\
  Rithmic_Baselines\
  Rollbacks\
  Restore_Conflicts\
```

Examples:

```text
SC_Data\NQZ14-CME.scid.gz
Rithmic_Baselines\NQH22-CME.scid__NQH2.CME.scid.gz
Rollbacks\NQH26-CME.scid__NQH6.CME.scid.gz
Rollbacks\manual-20260808-180000-000__NQH6.CME.scid.gz
```

The two-digit SC Data source name in a Rithmic backup filename prevents
one-digit-year decade ambiguity without splitting backups into directories.

SC Data archiving is always explicit. Normal Update never removes or compresses
SC Data source files.

## Recovery and rollback

`SCID_Bridge_Backups` is recovery staging used during atomic replacement. It is
not a permanent archive.

When a persistent rollback is required, it is stored under `Rollbacks`.

Before a manual Rithmic rollback overwrites a different current target, the
bridge first creates a verified manual undo backup. The selected backup is
retained after rollback, and the restored target is re-evaluated by the next
normal Update.

## Logs

The configured log folder contains:

```text
bridge-*.log
preflight-*.log
archive-*.log
restore-*.log
rollback-*.log
storage-*.log
cleanup-*.log
setup.log
```

Console output is intentionally compact. Detailed record counts, validation
metrics, timing, hashes, and errors are written to the logs.

## Documentation

- [Installation](docs/INSTALLATION.md)
- [Usage](docs/USAGE.md)
- [Technical design](docs/TECHNICAL.md)
- [Storage and recovery](docs/STORAGE.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Development](docs/DEVELOPMENT.md)
- [Release process](docs/RELEASE.md)
- [Security and data integrity](SECURITY.md)

## Project status

This is an experimental pre-release build.

The project is not affiliated with or endorsed by Sierra Chart, Rithmic, CME
Group, or their affiliates.

## License

Mozilla Public License 2.0. See [LICENSE](LICENSE).


## File compression

On volumes that support per-file compression, bridge-generated Rithmic `.scid`
and `.dly` files are created with Windows file compression enabled before their
payload is written. The final published target is verified to retain that
compression state.

SC Data and Rithmic files keep their normal logical byte length and file
format. Compression only changes physical allocation on disk.

Storage Report also detects existing uncompressed Rithmic market-data files and
can compress them in place after explicit confirmation. Sierra Chart must be
closed for that operation. Normal Update reports existing uncompressed files
but does not recompress them automatically.

GZip archive compression remains separate from Windows file compression.
