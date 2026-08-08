# Changelog

All notable changes to this project will be documented here.

The project uses pre-stable semantic versioning while the file-conversion behavior and supported symbol mappings are being validated.

## v0.0.1 - 2026-08-07

Initial Git-tracked version.

### Added

- SC Data futures filename discovery
- automatic mapping to Rithmic-style futures filenames
- overlapping-file raw-price scale verification
- chunked SCID conversion
- preservation of Sierra single-trade and unbundled-trade `Open` markers
- preservation of timestamps and trade/volume fields
- preservation of genuinely newer Rithmic live records
- boundary guard for live/backfill overlap
- structural and sampled-record validation
- rolling backups and per-run logs
- processed-file state so unchanged contracts are skipped
- File Explorer integration for folders and folder backgrounds
- direct command-line launcher
- Windows self-test and GitHub Actions workflow
