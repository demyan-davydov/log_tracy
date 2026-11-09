# Reviewing a Change Against the Rules

A review of a diff against the rules of this repository: what a general bug hunt doesn't know.
It complements a correctness review, it doesn't replace one. It reports, it doesn't fix.

## Scope

- By default the work of the current branch: `git diff master...HEAD` plus the uncommitted
  changes (`git diff HEAD`). On `master`: the uncommitted changes only. A range, a commit or
  paths given explicitly replace the default.
- Read every changed hunk and, where a rule is about it, the code around it.

## What to Read

1. `.ai/rules/INDEX.md`, then the rule files of the areas the diff touches.
2. The knowledge files of those areas (`.ai/knowledge/INDEX.md` says which).

## What to Check, in This Order

1. **Red Flags** of the rule files read: each one is reported, even when the rest is sound.
2. **Boundaries:** imports against the package order (`.ai/knowledge/architecture.md`); the
   script reaches the backend only through `backend.js` and Sciter only through
   `platform.js`; logic in Sciter-free modules, not in `MainWindow` or DOM code.
3. **Texts for the user:** literals in `tr` / `trc` / `trn` / `trParts` / `data-tr*`,
   `uiText` in the backend, catalogs updated (`node scripts/i18n-extract.mjs --check`).
4. **Tests:** new behaviour has a test (D unittest or `tests/js`); a test that could not have
   failed before the change is named as a regression guard.
5. **Resources:** a new file of `resources/` is in `ui/app_resources`; a column look is in
   `table.css`, not the format; a new color is in both themes.
6. **Docs and context:** a new format in `docs/formats.md`; a feature branch has its story in
   `docs/stories/`; things left for later in `docs/backlog.md`; a moved responsibility or a new
   extension point in `.ai/knowledge/`; a general UI requirement in `.ai/rules/ux.md`.
7. **UX:** behaviour against `.ai/rules/ux.md`. A layout or style concern is reported as a
   question for the user, never as a fix (`.ai/rules/ui.md`).

## Report

- One entry per finding: `file:line`, the rule (file and a short quote), what breaks and when.
  Red Flags first, then the order above.
- What was checked and found fine is one line, not a list.
- Nothing found is a valid result: say so.
- No edits: the person or agent who asked decides what to fix.
