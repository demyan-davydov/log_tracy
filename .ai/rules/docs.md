# Documentation Rules

## Scope

Applies to comments, `docs/` and `.ai/`.

## Languages

- Code, comments, commit messages and `.ai/` are in English.
- Documentation for people (installing, building, configuring, using: `README.md`,
  `docs/building.md`) is in English, one version only: two language versions drift apart.
  Older docs still in Russian (`docs/formats.md`, `docs/ui-guidelines.md`) are not
  translated unasked.
- The story of a feature (`docs/stories/`, what and why) and `docs/backlog.md` are in Russian.

## Where Things Go

- A finished feature has its story in `docs/stories/<feature>.md`: what was decided and why,
  including what was tried and rejected.
- What was noticed but left for later goes to `docs/backlog.md`, with enough context to pick
  it up.
- A format or a variant added or planned: `docs/formats.md`.
- A responsibility moved or an extension point added: the knowledge file of its area in
  `.ai/knowledge/`.

## Comments

- Every module starts with a `//!` comment stating its responsibility (D) or a leading `//`
  comment (script).
- Comment intent, invariants, edge cases, concurrency assumptions and code shaped to avoid a
  specific bug. Don't comment what the code already says.
