# Publishing to GitHub

The first Git-tracked version is:

```text
v0.0.20
```

## Initial repository

```bash
git init
git add .
git commit -m "Initial release: v0.0.20"
git branch -M main
git remote add origin https://github.com/CrownOpsEng/Sierra-HistoryBridge.git
git push -u origin main
```

## Tag

```bash
git tag v0.0.20
git push origin v0.0.20
```

## Build the release archive

On Windows:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```

Attach:

```text
dist\SierraHistoryBridge-v0.0.20.zip
```

to the GitHub Release.

The Windows CI workflow runs the SCID self-test, package test, and release builder on pushes and pull requests.
