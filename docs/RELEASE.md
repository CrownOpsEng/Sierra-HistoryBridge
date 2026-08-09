# Release process

This repository is private.

## Release checklist

1. run `tests\Run-SelfTest.ps1`
2. run `tests\Test-Package.ps1`
3. run `scripts\Build-Release.ps1`
4. install or repair the built package on Windows PowerShell 5.1
5. run Storage Report
6. run a no-change Update
7. test one SC Data archive/restore cycle on copied data
8. test one Rithmic rollback cycle on copied data
9. verify Explorer and Start Menu entries
10. record the release SHA-256

## Version

Current release:

```text
v0.0.26
```

## Repository tag

When the release is accepted:

```bash
git tag v0.0.26
git push origin v0.0.26
```

The repository and release package are private unless the owner explicitly
changes the distribution policy.
