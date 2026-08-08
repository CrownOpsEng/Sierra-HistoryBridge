# Security and data integrity

Sierra History Bridge modifies local Sierra Chart market-data files. Data integrity is the primary safety concern.

## Reporting a vulnerability

Report vulnerabilities and sensitive integrity problems through [GitHub
private vulnerability reporting][private-report]. Do not open a public issue
when a report contains an unpatched vulnerability, private data, credentials,
or information that would make exploitation easier.

## Recovery design

For an existing Rithmic target, conversion is written to a temporary file first. The output is validated before the existing target is replaced, and the previous target is retained as a rolling backup.

## Report a data-integrity problem

Include:

- Sierra History Bridge version
- Windows version
- Sierra Chart version
- source and target filenames
- the latest bridge log
- the setup log if installation integration is involved
- whether Sierra Chart was open
- the smallest copied dataset that reproduces the issue, if it can be shared safely

Do not include brokerage credentials, account secrets, or unrelated trading records.

## Recovery files

Bridge backups are stored under:

```text
SierraChart\Data\SCID_Bridge_Backups
```

Restore a backup only with Sierra Chart closed.

[private-report]: https://github.com/CrownOpsEng/Sierra-HistoryBridge/security/advisories/new
