# Security and data integrity

Sierra History Bridge modifies local Sierra Chart market-data files. Data
integrity is the primary safety requirement.

## Reporting a vulnerability

Report vulnerabilities and sensitive integrity problems through [GitHub
private vulnerability reporting][private-report]. Do not open a public issue
when a report contains an unpatched vulnerability, private data, credentials,
or information that would make exploitation easier.

## File replacement

A target is not replaced until temporary output has been written, durably
flushed, and validated.

Where rollback evidence is required, the existing Rithmic target is preserved
in a verified compressed backup.

## Archive and restore

Archive files are verified by decompression, byte count, and SHA-256 before the
source is removed.

Restore verifies the selected archive and restored output.

## Rithmic rollback

Rollback preserves a different current target as a verified manual undo backup
before replacement.

The selected rollback backup is retained.

## Sensitive information

Do not place brokerage credentials, account secrets, API keys, or unrelated
trading records in issue reports, logs, or test fixtures.

## Reporting a non-sensitive integrity problem

For an integrity problem, record:

- application version
- Windows and Sierra Chart versions
- source/target filenames
- relevant logs
- Sierra Chart connection/open state
- the smallest copied dataset that reproduces the problem

[private-report]: https://github.com/CrownOpsEng/Sierra-HistoryBridge/security/advisories/new
