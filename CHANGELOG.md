# Changelog

## v0.0.15 - 2026-08-07

Initial pre-stable release.

### History processing

- eligible-contract alias collision handling now groups by Rithmic target filename

- fixed the rolling-window PowerShell expression to avoid multiline member chaining on Windows PowerShell 5.1

- SCID conversion now checks available free space and defers before writing when the temporary output cannot fit with a 256 MB reserve

- startup storage maintenance safely prunes leftover backups and stale bridge temporary files

- live and temporary-merge rollback backups are retained as one compressed archive

- historical SCID and DLY replacement backups are pruned after successful post-replacement verification

- preflight validation can compare directly against compressed Rithmic baselines without extracting them

- compressed baseline filenames preserve the original Rithmic filename under a two-digit source-contract directory

- original Rithmic SCID baselines are now stored as verified compressed `.gz` archives instead of permanent full-size `.bak` files

- previously managed targets without a baseline are labeled as non-independent validation references

- later preflight checks prefer the immutable Rithmic baseline instead of validating against bridge-generated output

- first-use Rithmic SCID targets are preserved as immutable compressed Rithmic-baseline validation references

- live SCID overlap validation runs after disconnect/close and before conversion

- ambiguous preflight results require an interactive decision; unattended runs defer them

- temporary historical merges remain pending and are rebuilt when SC Data becomes complete

- strongly validated incomplete sources can optionally use a temporary SC Data/Rithmic tail merge

- incomplete historical SCID sources no longer silently replace more complete Rithmic targets

- preflight reports timestamp coverage, ordering, per-second volume, bid/ask volume, last-price agreement, aggregate-volume difference, and data richness

- added full SCID preflight comparison between overlapping SC Data and Rithmic files before replacement

- historical SCID sources that have not reached the matching Daily contract endpoint are deferred

- live target changes during conversion defer the update and discard temporary output

- source changes during conversion defer the update and discard temporary output

- historical replacement validates exact source/output record count and byte length

- live SCID handoff uses a verified whole-second boundary backed by matching trade aggregates

- live Rithmic records are preserved only when the target is genuinely newer than the SC Data source

- historical SCID contracts now replace Rithmic history completely instead of preserving a historical Rithmic suffix

- metadata can be refreshed without rewriting an already synchronized DLY target

- existing DLY targets are semantically compared during state migration to avoid one-time unnecessary rewrites

- SCID source changes no longer cause an unchanged DLY file to be rewritten

- Historical Daily update detection now uses a SHA-256 content signature instead of file modification time

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
