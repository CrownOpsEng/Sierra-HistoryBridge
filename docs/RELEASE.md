# Release Process

Release artifacts must contain the repository's `LICENSE` file and retain required source-file licensing notices.

## v0.0.33 validation checklist

1. run `tests\Run-SelfTest.ps1`
2. run `tests\Test-Package.ps1`
3. run `scripts\Build-Release.ps1`
4. run Setup/Repair on Windows PowerShell 5.1
5. verify package parser and C# `Add-Type` validation
6. confirm resolved Sierra/Data/Storage/Temp/Logs paths
7. run Storage Report
8. run a no-change Update
9. test multi-select Archive/Restore on safe copied data
10. test multi-select Rollback on safe copied data
11. verify RT/SC/MX/FR/UN filenames and metadata
12. verify an MX rollback displays its metadata cutoff when available
13. verify Baselines contains RT only
14. verify `HistoryBridgeTemp` disappears when empty
15. verify Explorer and Start Menu entries
16. record release SHA-256

## Merge-specific smoke test

Use a current contract where SC Data and Rithmic overlap.

Confirm the Update log records:

```text
handoff_datetime
handoff_verified_trade_seconds
output_sha256
```

If a Rithmic tail is preserved, confirm:

```text
handoff_verified_trade_seconds >= 3
```

and the resulting backup/target provenance is MX.

## Version

```text
v0.0.33
```

Do not change the version unless the owner explicitly chooses a new release
version.
