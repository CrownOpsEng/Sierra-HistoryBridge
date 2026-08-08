# Changelog

All notable changes to Sierra History Bridge are documented here.

The project uses pre-stable semantic versioning while conversion behavior and supported service/symbol mappings are validated.

## v0.0.7 - 2026-08-07

Initial Git-tracked version.

### Application

- newest eligible contract owns a reused one-digit Rithmic filename; stale decade state is discarded

- managed cache retirement for verified bridge-created targets that age out of the rolling window

- archive-only filtering instead of stopping on decade-separated Rithmic filename collisions

- rolling Rithmic compatibility window: 5 years usable history + 3-month rollover buffer + 6-month forward buffer

- warning when a symbol group spans beyond Sierra Chart's practical five-year continuous-futures window under Rithmic symbology

- hard safety check for decade-separated SC Data contracts that collide under Rithmic one-digit-year filenames

- final per-file result lines are never truncated, preserving exact verification counts even in narrow consoles

- exact source, preserved-tail, and output record totals retained in each final console status line

- conversion/flush/validation/replacement timings recorded in the detailed run log

- one persistent summary line per processed file instead of percentage-line spam

- compact in-place per-file status display for conversion, flush, validation, replacement, and final verification

- stores minimum target record/timestamp metadata so deleted or recreated targets are automatically rebuilt

- detects header-only Sierra/Rithmic placeholder files and labels them explicitly in the update plan

- validates processed target files before treating a source as unchanged

- verifies the replaced target record count after every successful conversion

- writes the run log before conversion begins and appends success/failure diagnostics immediately

- preserves SC Data record order when isolated source timestamps move backward and reports the anomaly

- scans SC Data futures `.scid` files
- maps SC Data futures filenames to Rithmic-style filenames
- verifies raw-price conversion scales from overlapping files
- converts SCID records in large chunks
- preserves timestamps, trade counts, total volume, bid volume, and ask volume
- preserves Sierra single-trade and CME unbundled-trade `Open` markers
- preserves genuinely newer Rithmic records after the SC Data historical section
- uses a handoff guard to reduce live/backfill duplication
- validates converted output before replacement
- creates rolling Rithmic target backups
- writes per-run logs
- skips unchanged source contracts on later runs

### Windows integration

- Windows PowerShell 5.1-compatible embedded C# compilation using plain `Add-Type`
- safe allocation-free price-field conversion with no custom compiler switches
- allocation-free safe price-field conversion with no `/unsafe` compiler requirement
- base-framework SCID converter with no LINQ/System.Core dependency during Windows PowerShell 5.1 compilation

- current-user installation under the local Programs directory
- optional all-users installation under Program Files
- separate per-user mutable application data
- File Explorer folder/background command
- optional Start Menu / All apps shortcuts
- Windows Installed apps registration
- standard uninstall command
- repair/update maintenance mode
- clean repair payload stored with the installed setup files
- migration cleanup for earlier development install locations

### Project

- public GitHub-ready repository layout
- user, installation, technical, troubleshooting, development, and publishing documentation
- contribution and security guidance
- synthetic SCID self-test
- release-package test
- Windows GitHub Actions workflow
- reproducible release builder
