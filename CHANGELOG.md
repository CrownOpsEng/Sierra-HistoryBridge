# Changelog

## v0.0.12 - 2026-08-07

Initial pre-stable release.

### History processing

- reload/recalculate guidance is shown only when at least one update or retirement completed

- failed operations now record PowerShell stack and position details in the run log

- reporting/status errors no longer classify an already committed file update as a conversion failure

- fixed PowerShell status formatting that could report every completed contract as failed

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

- run.cmd now keeps nonzero startup failures visible

- package tests now parse every PowerShell source file

- removed an unnecessary type literal from SCID timestamp conversion

- fixed a PowerShell parse error in the live-aware final warning condition

- updated open historical charts are directed to Chart > Reload and Recalculate

- skipped live SCID sources remain pending for a later run

- live SCID updates offer disconnect/close-chartbooks, close-Sierra, skip-live, or cancel choices

- recent SCID targets receive live-file handling instead of a global Sierra Chart shutdown requirement

- Sierra Chart can remain open for historical-only updates

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
