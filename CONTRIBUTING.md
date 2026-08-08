# Contributing to Sierra History Bridge

Contributions incorporated into Sierra History Bridge are distributed as part
of the project under the [Mozilla Public License 2.0](LICENSE).

Contributors retain ownership of their contributions. Before a pull request
containing copyrightable contributions can be merged, the contributor must have
accepted the [Contributor License Agreement](https://gist.github.com/CrownOpsEng/2ebfe5aadfda5dc86da445ebc6d27b98).
The repository includes an identical
[project copy](CONTRIBUTOR-LICENSE-AGREEMENT.md).
The agreement gives Chris Wright additional rights, including the ability to
sublicense and distribute contributions under other license terms. When an
employer or another organization owns the contribution, an authorized
representative must accept the same agreement for that legal entity.

The required CLA Assistant check records acceptance of the current agreement
for individuals. If an employer or another organization owns relevant rights,
open a non-sensitive issue requesting a private entity CLA exchange channel. Do
not place signed agreements, private contact details, or entity records in an
issue or pull request. An entity contributor is approved only after an
authorized representative signs for the legal entity and the contributor's
GitHub username is recorded.

Every human copyright holder must be covered. Identify all co-authors in the
pull request; a co-author not covered automatically by CLA Assistant must be
verified before merge. Necessary GitHub-owned bots and the Project Steward may
be exempted from the automated check.

## Before changing code

- Preserve market-data integrity and reversible file operations.
- Use copied SCID/DLY files, never an active trading Data folder.
- Keep Windows PowerShell 5.1 compatibility.
- Add or update a focused test when behavior changes.
- Document user-visible safety or storage-policy changes.

## Commit standard

Use Conventional Commit-style subjects:

```text
<type>(<scope>): imperative summary
```

Allowed types are `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`,
`chore`, `perf`, and `revert`. Use a short scope such as `scid`, `archive`,
`restore`, `rollback`, `installer`, `storage`, or `docs` when it adds useful
context.

Keep the subject under 72 characters, use the imperative mood, and omit a
trailing period. In the body, explain the reason, completed behavior, safety or
compatibility impact, and verification actually performed. Correct syntax,
fixtures, compiler compatibility, and CI in the relevant change before it is
merged. See [the detailed commit standard](docs/COMMIT-STANDARDS.md).

Install the repository's optional commit-message hook with:

```console
git config core.hooksPath .githooks
```

GitHub validates all reachable commit messages and the pull request title. A
pull request cannot merge until its commit-policy, Windows test, and CLA checks
pass.

## Testing

Run both test suites before proposing a change:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-SelfTest.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

For a release candidate, also run:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Release.ps1
```
