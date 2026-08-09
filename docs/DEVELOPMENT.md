# Development

## Repository layout

```text
src/                  application and C# engine
scripts/              setup and release tooling
tests/                self-test and package checks
docs/                 documentation
.github/workflows/    Windows test workflow
```

## Run from the repository

```text
run.cmd
```

## Tests

Run on Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SelfTest.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

The self-test covers SCID conversion, price scaling, live-tail preservation,
Historical Daily processing, compressed archives, and control-marker
preservation.

The package test checks repository structure, Windows PowerShell constraints,
current archive/state policy, installer wiring, Explorer integration, and
release construction.

Use copied market-data files for real-data development tests. Do not develop
against an active production Sierra Data directory.

## Build

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Output is written under `dist`.

The release contains `setup\payload.zip`; Repair uses that clean packaged
payload.

## Design priorities

1. data integrity
2. reversible replacement
3. explicit failure behavior
4. simple Windows operation
5. measurable validation
6. minimal persistent duplication

Do not hard-code a price scale without reproducible overlapping source/target
evidence.
