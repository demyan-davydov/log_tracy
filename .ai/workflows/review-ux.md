# Review Lens: UX

Scope and report: `.ai/workflows/review.md`. The question: does the change behave and look as
the user's requirements say, in every state the user can reach?

## What to Read

- `.ai/rules/ux.md` (the user's requirements: the source of truth), `.ai/rules/ui.md`,
  `docs/ui-guidelines.md` (spacing, radii, typography), `.ai/knowledge/ui.md`.
- `.ai/knowledge/sciter.md` for what the code may expect from Sciter and doesn't get.
- The changed markup, styles and scripts, and the flows that reach them.

## Red Flag: Restyling Existing UI Unasked

A change of the layout or look of existing UI that the task didn't ask for (`.ai/rules/ui.md`).
Report it; a concern about the existing layout itself is a question for the user, never a fix.

What the task asked is read before this flag is raised: the story of the feature
(`docs/stories/<feature>.md`), the commit messages of the change, the request in the prompt. A
change of look that serves the feature (a mark redrawn in the style the feature introduces) is
part of it; flag only what nothing there explains, and say what was checked.

## Checklist

1. **The requirements of `ux.md`** the change touches, each one by number: conventions and
   positions, no duplicate controls, hide what can't be used, no overflow scrollbars, content
   decides the size, notices that disappear, status views, empty states, the table rules,
   queries applied on commit, recent files, Settings. A contradiction with a rule is a finding,
   naming the rule.
2. **Every state of the change:** no document, loading, filtering, searching, failed, file lost,
   an empty result, one record, very many; a narrow window and a low panel; a long name or
   path; both themes; a long translation (the pseudo locale, `PSEUDO_LOCALE=1`). A state the
   change forgets is a finding.
3. **Feedback:** a refused action says why; a long one shows progress and can be cancelled;
   nothing happens silently; no dead end (after a failure the user knows what to do next).
4. **Keyboard and focus:** the shortcuts of the menu model, Escape and Enter where expected,
   the focus where the user works (not left in a hidden panel), mnemonics on Windows/Linux.
5. **Texts:** short, as the rest of the interface says things; translated
   (`.ai/knowledge/i18n.md`); not built from parts that won't translate.
6. **Consistency:** the same thing looks and behaves the same everywhere (buttons, popups,
   notices, the two tables); sizes on the scale of `docs/ui-guidelines.md`; colors from the
   theme variables, in both themes.
7. **Sciter traps** of `.ai/knowledge/sciter.md` the change walks into (a popup handled on the
   wrong element, `:empty` not re-evaluated, a hidden log table).

## Looking at It

When the change alters what is shown and the code alone can't tell how it looks, take **one**
screenshot (`node scripts/screenshot.mjs --open <log> --out <scratch>/review.png`, a local log
of `test_data/` if any; `.ai/workflows/preview-ui.md`) and judge from it. Say what it showed;
no rounds of retakes. Hover and an open popup are checked by driving the app (macOS:
`app.mjs hover`, then `shot`, which writes each open popup beside the window; `/app`). What
neither can show (a press of the mouse, a drag, the other systems) is reported as
**suspected**, to be looked at by the user.

## Not This Lens

The rules of the repository, performance and threads: other lenses.
