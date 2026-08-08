# Changelog

## v0.0.10 - 2026-08-07

Initial pre-stable release.

### History processing

- DLY-only contracts are included even when no matching SCID source exists
- Historical Daily scale can be verified from overlapping DLY files
- old target-only Daily rows are not carried across reused one-digit contract names

- SC Data `.scid` to Rithmic `.scid` conversion
- independent Historical Daily `.dly` discovery and processing
- verified raw-price scale per root/exchange group
- preservation of newer Rithmic intraday records
- date-based Historical Daily merge with latest-date overlap handling
- output validation before target replacement
- rolling target backups
- exact per-file record totals in the console and log
- source timestamp inversion reporting without record reordering

### Rolling history management

- five-year history range for Rithmic single-digit-year symbols
- three-month older rollover buffer
- six-month forward-contract buffer
- automatic exclusion of older two-digit-year SC Data contracts
- metadata-checked retirement of bridge-managed Rithmic files

### Windows integration

- current-user and all-users installation
- File Explorer folder/background command
- optional Start Menu shortcuts
- Windows Installed apps registration
- repair/update and uninstall support
- per-user configuration and processing state
- Windows PowerShell 5.1-compatible C# compilation

### Project

- SCID and Historical Daily self-tests
- release-package test
- Windows CI workflow
