# Publishing to GitHub

The repository is prepared as the first pre-stable release, `v0.0.1`.

From the repository directory:

```bash
git init
git add .
git commit -m "Initial release: v0.0.1"
git branch -M main
git remote add origin https://github.com/CrownOpsEng/Sierra-HistoryBridge.git
git push -u origin main
git tag v0.0.1
git push origin v0.0.1
```

For a GitHub Release, attach the packaged Windows release archive:

```text
SierraHistoryBridge-v0.0.1.zip
```

The repository workflow runs the SCID conversion self-test on Windows for pushes and pull requests.
