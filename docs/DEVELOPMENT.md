# Development

## Repository layout

```text
src/                  application and SCID conversion engine
scripts/              setup and release-build tooling
tests/                synthetic SCID and package tests
docs/                 user and technical documentation
.github/workflows/    Windows CI
```

## Run the application from the repository

```text
run.cmd
```

## Run tests

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .	ests\Run-SelfTest.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .	ests\Test-Package.ps1
```

The SCID self-test creates synthetic source and target files in a temporary directory and checks:

- raw-price scale inference
- conversion
- newer Rithmic tail preservation
- backup creation
- special `Open` marker preservation

The package test checks repository layout, parses the PowerShell source, and builds a release package.

## Build a Windows release

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Output:

```text
dist\SierraHistoryBridge-v0.0.6
dist\SierraHistoryBridge-v0.0.6.zip
```

The release includes `setup\payload.zip`, which is retained after installation and used by Repair.
