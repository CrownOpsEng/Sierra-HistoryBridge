# Versioning

Sierra History Bridge follows Semantic Versioning 2.0.0 while it remains
experimental.

## Pre-1.0 policy

- Increment `0.0.z` for every experimental snapshot that should be retained or
  referenced, including material fixes, features, packaging changes, and
  documentation that affects how the version is used. Number and tag a
  snapshot only after its required platform checks pass.
- `v0.1.0` is reserved for the first ready-to-release experimental milestone.
  Do not create, tag, or claim that release until the owner explicitly decides
  the project is ready.
- After `v0.1.0`, use normal pre-1.0 Semantic Versioning: patch for compatible
  corrections and minor for a coherent experimental feature set or an
  intentionally incompatible behavior, storage-layout, CLI, or configuration
  change.
- Pre-release builds use `-alpha.N`, `-beta.N`, or `-rc.N`, for example
  `v0.1.0-rc.1`.
- Build metadata may be appended after `+` when needed for traceability, for
  example `v0.1.0-rc.1+20260809`.

## Release practice

Before publishing, update `VERSION`, `CHANGELOG.md`, release documentation,
and user-visible version text together. Tag the exact release commit as
`vMAJOR.MINOR.PATCH`. Do not reuse or move a published tag.

Version `1.0.0` requires a separate deliberate decision that the supported
workflow, data-safety behavior, configuration, and installer experience are
stable enough to maintain as a public compatibility promise.
