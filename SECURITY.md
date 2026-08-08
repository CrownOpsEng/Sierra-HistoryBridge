# Security and data integrity

Sierra History Bridge modifies local Sierra Chart market-data files, so data integrity is the primary safety concern.

## Reporting a vulnerability

Report vulnerabilities and sensitive integrity problems through [GitHub
private vulnerability reporting][private-report]. Do not open a public issue
when a report contains an unpatched vulnerability, private data, credentials,
or information that would make exploitation easier.

## Reporting a non-sensitive integrity problem

For a suspected data-corruption issue, include:

- Sierra History Bridge version
- source and target symbol filenames
- the latest bridge log
- whether the target existed before the run
- whether Sierra Chart was running
- the smallest reproducible copied dataset you can safely share

Do not attach brokerage credentials, account secrets, or unrelated trading records.

## Recovery

Existing targets receive a rolling `.bak` file before replacement. Restore that backup with Sierra Chart closed if a converted target must be rolled back.

[private-report]: https://github.com/CrownOpsEng/Sierra-HistoryBridge/security/advisories/new
