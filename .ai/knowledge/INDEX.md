# Log Tracy Knowledge Index

## Overview

Log Tracy is a desktop viewer for DLT and text logs (macOS, Linux, Windows), written in D
with the Sciter UI framework through its own minimal binding. The UI is vanilla HTML/CSS/JS in
`resources/`, not Reactor style. Files can be ~1 GB: nothing loads a whole log into memory.

Use this file to choose the next context file. Do not load every file by default.

## Repository Guardrails

- Build and test with ldc2 through `node scripts/build.mjs` (commands in `AGENTS.md`, for
  people in `docs/building.md`). `node scripts/build.mjs test` runs the D unittests, the JS
  tests and `scripts/check-ai-context.mjs` (names of `.ai/` the code lost): run it before
  saying a change is done.
- The packages and what each may import: `.ai/knowledge/architecture.md` (Packages).
- The files of `resources/` are built into the executable: a JS/CSS/HTML change needs a rebuild.
- `settings.json` sits next to the executable: every build folder has its own.

## Primary Context

- Architecture: `.ai/knowledge/architecture.md`
  - Data flow from bytes to the table, the script ↔ backend bridge, settings, threads and
    indexes, the packages. Read before a change that crosses packages or the script/backend
    boundary, and for a design review.
- Formats and records: `.ai/knowledge/formats.md`
  - Formats, detection, `LogMessage`, adding a format.
- Filters and search: `.ai/knowledge/filters.md`
  - Filter rules, filter files, rule colors, the rule editor, search filters.
- The window and the script: `.ai/knowledge/ui.md`
  - Table columns and rows, document panels, menu, state machines, script modules, and the
    "if you need X, start here" map of `resources/`.

## Targeted Context

Load only when the task targets that area.

- Sciter behaviour and traps: `.ai/knowledge/sciter.md`
  - Before writing or debugging script/CSS that does anything beyond the obvious, and before
    blaming our code for a layout or event oddity.
- Translations: `.ai/knowledge/i18n.md`
  - Any text the user sees, in the script or the backend.
- Product background: `docs/formats.md` (formats supported and planned), `docs/fibex.md`
  (FIBEX decision), `docs/performance.md` (measurements), `docs/ui-guidelines.md` (visual
  standards), `docs/stories/` (why features are as they are).
