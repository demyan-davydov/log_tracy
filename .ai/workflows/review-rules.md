# Review Lens: Rules

Scope and report: `.ai/workflows/review.md`. The question: does the change follow the rules of
this repository?

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
6. **Docs and context:** a new format in `docs/formats.md`; a new environment variable in the
   table of `docs/building.md`; a feature branch has its story in `docs/stories/`; things left
   for later in `docs/backlog.md`; a moved responsibility or a new extension point in
   `.ai/knowledge/`; a general UI requirement in `.ai/rules/ux.md`.

Performance, threads and UX are other lenses: leave them to those unless a rule file names it
(a Red Flag of `.ai/rules/ui.md` is still reported here). Before raising "Restyling Existing UI
Unasked", read what the task asked (the story of the feature, the commit messages, the
request): a change of look the feature explains is part of it.
