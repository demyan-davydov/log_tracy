# Script Rules

## Scope

Applies to `resources/*.js` and the scripts of `resources/*.htm`. UI rules (`.ai/rules/ui.md`)
hold as well.

## Boundaries

- The backend is reached only through `resources/backend.js` (one function per xcall); the
  services of Sciter (dialogs, clipboard, window frame, OS) only through
  `resources/platform.js`. Other modules call neither `Window.this.xcall` nor Sciter services
  directly.
- Logic worth a test goes into a module free of Sciter and the backend, tested by `tests/js`
  (it imports its neighbours with `./`). The modules that touch the DOM only render.
- What the window shows comes from `resources/window-state.js`; `script.js` renders it.

## Red Flag: Non-Literal Texts

Every text the user sees goes through `tr` / `trc` / `trn` / `trParts` with a string literal,
or `data-tr*` in markup built once. A variable or a concatenation can't be found by
`scripts/utils/i18n-extract.mjs`. Catalogs are brought up to date in the same change.

## Resources

- A new file of `resources/` is added to the list of `ui/app_resources` (a unittest fails
  until it is).
- A JS/CSS/HTML change needs a rebuild to be seen in the app.
- Use the Sciter idioms of `.ai/knowledge/sciter.md` (e.g. `removeAttribute`, never assigning
  null to an attribute; `Element.append` takes one node).
