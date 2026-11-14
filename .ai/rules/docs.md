# Documentation Rules

## Scope

Applies to comments, `docs/` and `.ai/`.

## Languages

- Code, comments, commit messages and `.ai/` are in English.
- Documentation for people (installing, building, configuring, using: `README.md`,
  `docs/building.md`) is in English, one version only: two language versions drift apart.
  Older docs still in Russian (`docs/formats.md`, `docs/ui-guidelines.md`) are not
  translated unasked.
- The story of a feature (`docs/stories/`, what and why), the experiments (`docs/experiments/`)
  and `docs/backlog.md` are in Russian.

## Other Products

- Comments, `docs/`, `.ai/` and the names of tests and identifiers don't name other products
  (log viewers, their plugins and test suites, vendor tools) or point at their sources: a
  behaviour is described as ours, or as what DLT tools commonly do. A product name stays
  only where it names a file format (`.dlf`, Vector ASC) and in texts of the UI the user
  decided to keep.

## Where Things Go

- A finished feature has its story in `docs/stories/<feature>.md`: what was decided and why,
  including what was tried and rejected.
- What was noticed but left for later goes to `docs/backlog.md`, with enough context to pick
  it up.
- An experiment or a measurement a decision rests on (a way of working compared, an approach
  tried) goes to `docs/experiments/<date>-<name>.md` (Russian): the question, the conditions
  (date, model, versions, how to repeat it), the data, the result with its caveats, the
  decision. The story of a feature links to it instead of retelling the numbers. Reference
  numbers of the app itself stay in `docs/performance.md`.
- A format or a variant added or planned: `docs/formats.md`.
- An environment variable the program reads: the table "Environment variables for
  development" of `docs/building.md`. It is named for what it does, without the name of the
  app or of a log format (`OPEN_AT_START`, `SCITER_DEBUG_MODE`, not `DLT_...`).
- A responsibility moved or an extension point added: the knowledge file of its area in
  `.ai/knowledge/`.

## Comments

- Every module starts with a `//!` comment stating its responsibility (D) or a leading `//`
  comment (script).
- Comment intent, invariants, edge cases, concurrency assumptions and code shaped to avoid a
  specific bug. Don't comment what the code already says.
