# Commit Standards

Each commit must be one coherent, reviewable change. Sierra History Bridge
manipulates valuable market data, so its history must explain intent, safety
impact, and verification without requiring a reviewer to infer intent from a
diff.

## Subject

Use this Conventional Commit form:

```text
<type>(<scope>): <imperative summary>
```

The subject must:

- use an allowed lowercase type;
- use a short lowercase scope when it improves discovery;
- describe the result in the imperative mood (`add`, `preserve`, `reject`);
- be specific enough to distinguish the change from nearby commits;
- contain no trailing period; and
- stay within 72 characters, with 50 characters preferred when practical.

Allowed types:

- `feat`: new user-visible capability
- `fix`: corrected behavior or a safety defect
- `perf`: measured performance improvement
- `refactor`: implementation change with no intended behavior change
- `test`: test or fixture changes only
- `docs`: documentation only
- `build`: packaging, setup, generated artifacts, or dependencies
- `ci`: continuous-integration configuration
- `chore`: narrowly scoped maintenance not covered above
- `revert`: an explicit reversal of an earlier commit

Useful scopes include `scid`, `daily`, `merge`, `archive`, `restore`,
`rollback`, `storage`, `installer`, `explorer`, `validation`, `release`, and
`docs`. Omit the scope when no single scope describes the whole commit.

Good subjects:

```text
fix(rollback): preserve undo state before replacement
feat(archive): add verified bulk restore filters
test(scid): cover a partial final-second handoff
docs(versioning): define the pre-1.0 release policy
ci(windows): run PowerShell 5.1 package validation
```

Avoid vague or process-oriented subjects such as `fix bug`, `updates`,
`address review`, `WIP`, or `try CI again`.

## Body

Separate the body from the subject with one blank line. Wrap prose at roughly
72 characters. Explain the completed change, not the sequence of attempts that
produced it.

Code, installer, CI, and data-policy commits must cover:

1. why the change is needed;
2. what behavior or invariant changed;
3. market-data, rollback, compatibility, or operational impact;
4. verification actually performed; and
5. any intentional limitation or follow-up.

Use bullets when several independent results need to be called out. Do not add
empty headings or claim tests that were not run. If a platform-specific check
could not run locally, say so and identify the CI job that provides it.

## Atomicity and fixups

- Keep implementation, focused tests, and directly affected documentation in
  the same commit.
- Do not mix unrelated reformatting, renames, or cleanup with behavior changes.
- Correct syntax, fixtures, compiler compatibility, and CI in the relevant
  change before it is merged.
- Keep a later fix distinct when it changes safety policy, user-visible
  behavior, storage format, or an already published release.
- Do not merge `fixup!`, `squash!`, `WIP`, or CI-retry commits.

## Trailers and breaking changes

Use standard trailers only when they convey real metadata:

```text
Fixes: #123
Co-authored-by: Name <email@example.com>
```

For an incompatible change, add `!` before the colon and a
`BREAKING CHANGE:` trailer that describes the migration:

```text
feat(storage)!: replace the archive directory layout

BREAKING CHANGE: Run Repair before using archives created by older builds.
```

Do not add `Signed-off-by` unless the contributor intentionally uses a DCO
workflow. The contributor license agreements are handled separately.

## Automated enforcement

Run `git config core.hooksPath .githooks` to enable the repository's optional
local `commit-msg` hook. GitHub runs the same cross-platform Python validator
over all reachable commits and validates pull request titles before merge.

The automated check enforces the subject form, length, prohibited temporary
subjects, and a meaningful multi-line body for substantive commit types. It
does not replace author judgment: the body must still accurately explain the
reason, completed behavior, safety or compatibility impact, and verification.

## Release commits

A release-worthy snapshot includes its version text, changelog, focused tests,
and directly affected documentation in the commit that creates the behavior.
Tag that exact commit as `vMAJOR.MINOR.PATCH`. Create the tag only after the
required tests and workflow checks pass.
