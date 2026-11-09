# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DLT Explorer: a desktop viewer for DLT and text logs (macOS, Linux, Windows), written in D with
the Sciter UI framework through its own minimal binding (`source/sciter`: the C API in
`sciter/capi`, the D wrapper over it). The UI is vanilla HTML/CSS/JS in `resources/`, not
Reactor style. Files can be ~1 GB: nothing loads a whole log into memory.

The shared context of the repository is in `.ai/`: start at `.ai/INDEX.md`. This file keeps only
what every session needs.

## Read Before

- Writing or reviewing code: `.ai/rules/INDEX.md` and the rule files of the areas touched.
- A change in an area you haven't read this session: its file in `.ai/knowledge/`
  (architecture, formats, filters, ui, i18n, sciter).
- UI work: `.ai/rules/ux.md` (the user's UX requirements) and `.ai/knowledge/sciter.md`.
- Adding a format, a backend call, a resource file, updating Sciter, the git flow, a review by
  lenses, a screenshot of the app: its file in `.ai/workflows/` (most are skills
  too: `/add-format`, `/add-backend-call`, `/update-sciter`, `/review`, `/screenshot`).

The traps that cost most, whatever the task (the rest in `.ai/rules/` and
`.ai/knowledge/sciter.md`):

- Pass a `LogMessage` by `ref`, never `out`: `out` leaks its buffer on every decode.
- Never hide a log table itself with `display: none`: its cells stay 1px wide for good.
  Status views cover it (`.status-view.overlay`).
- Per-row work of a log table is hot: keep it cheap, measure before optimizing.
- `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12: check the month.
- Sciter: `attributes["x"] = null` writes "null" (use `removeAttribute`); `Element.append`
  takes a single node; assign `input.value`, not the `value` attribute.

## Commands

Build and test with **ldc2** (`--compiler=ldc2`); the scripts assume it too. One script on
every system, `scripts/build.mjs` (for people: `docs/building.md`):

```sh
node scripts/build.mjs                   # debug for this machine → build/osx-aarch64-debug/dlt_explorer
node scripts/build.mjs --release         # release; --arch x64|arm64 for another architecture
node scripts/run.mjs                     # builds as above (same options) and starts the app, its stdout here
node scripts/build.mjs test              # D unittests ("N modules passed unittests") + JS tests
node scripts/build.mjs dist              # release distribution in build/dist/<macos|linux|windows>/
node scripts/build.mjs check-windows     # from macOS/Linux: compiles app + unittests for Windows x64, no link
node scripts/build.mjs --help            # the commands and options (run.mjs --help too)
dub build --compiler=ldc2                # the same build without the script; dub test likewise
node --test tests/js                     # JS unit tests only (pure modules such as resources/new-tab.js)
node scripts/i18n-extract.mjs            # brings the translation catalogs up to the texts of the code
node scripts/screenshot.mjs --open <log> # the app's window with a log → build/screenshot.png (--help)
```

- `dub.sdl` puts every build in `build/<platform>-<arch>-<build type>/` (`osx-aarch64-unittest`
  for `dub test`) and copies the Sciter library of `libs/` next to it (`copyFiles`): a build
  runs from there, in a fresh worktree too. `libs/` is in Git LFS (`git lfs pull` after a
  clone), its Sciter version in `libs/VERSION`; the app's version is `VERSION`.
- One module that doesn't depend on Sciter can be tested on its own (the druntime runner has no
  filter and stops a module at its first failing `unittest`):
  `ldc2 -unittest -main -i -preview=in -preview=dip1000 -preview=dtorfields -Isource source/log_core/text/text_format.d -of=/tmp/t && /tmp/t`
- Keep the `-preview=in/dip1000/dtorfields` flags of `dub.sdl` when compiling by hand.
- The files of `resources/` are built into the executable: a JS/CSS/HTML change needs a
  rebuild, a new file is added to `ui/app_resources`.
- `settings.json` sits next to the executable and is rewritten on exit: every build folder has
  its own. Run a copy of the binary from another folder to keep the developer's own settings.
  A release build runs one copy per `settings.json`; debug builds run side by side.
- The script's `console.log` goes to the app's stdout as `info [script]: ...` lines.

## Packages

A package imports only the packages to its left (unittests may import more):

```
utils  ←  log_core  ←  formats  ←  domain  ←  ui  ←  app.d
utils  ←  sciter  ←  ui
```

The script reaches the backend only through `resources/backend.js` (one function per xcall,
done by `ui/app_session`) and Sciter's services only through `resources/platform.js`. Logic
worth a test lives in Sciter-free modules, D and JS alike.

## Conventions

- The main branch is `master`. Features go on a branch and are merged with `--no-ff`; small
  one-off fixes go straight on `master`. Details and what an agent may do on its own:
  `.ai/workflows/git.md`.
- Tests first: write the test, see it fail for the right reason, then change the code
  (`.ai/rules/tests.md`).
- Every module starts with a `//!` comment stating its responsibility. Use camelCase, write
  code, comments and `.ai/` in English. Docs for people (`docs/`) are in English; the story of
  a feature (`docs/stories/`) and `docs/backlog.md` are in Russian.
- Commit subjects are short, lower-case and imperative; on a feature branch they start with
  `<feature>: `.
- When a change moves a responsibility or adds an extension point, update its file in
  `.ai/knowledge/`; when the user states a general UI requirement, add it to `.ai/rules/ux.md`.
