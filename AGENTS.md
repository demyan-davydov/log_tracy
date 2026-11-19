# AGENTS.md

This file provides guidance to coding agents (Claude Code, Codex and others) when working with
code in this repository. `CLAUDE.md` only imports it, so Claude Code loads it into every session.

Log Tracy: a desktop viewer for DLT and text logs (macOS, Linux, Windows), written in D with
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
  lenses, a screenshot of the app, driving the running app: its file in `.ai/workflows/` (in
  Claude Code most are skills too: `/add-format`, `/add-backend-call`, `/update-sciter`,
  `/review`, `/screenshot`, `/app`).

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
node scripts/install-deps.mjs                   # checks LDC, dub, Git LFS, the C toolchain; --install installs what is missing
node scripts/build.mjs                          # debug for this machine → build/osx-aarch64-debug/log_tracy
node scripts/build.mjs --release                # release; --arch x64|arm64 for another architecture
node scripts/build.mjs --debug-channel          # the debug channel is in a build only with this (debug or --release)
node scripts/run.mjs                            # builds as above (same options) and starts the app, its stdout here
node scripts/test.mjs                           # D unittests ("N test(s) run, 0 failed."), JS tests, stale names of .ai/
node scripts/test.mjs --filter utils.fsm        # only the D unittests whose names start with it (repeatable), no JS tests
node scripts/test.mjs --module source/log_core/text/text_format.d  # one Sciter-free module, no dub
node scripts/test.mjs --brief                   # any build/test command: only what failed, the rest in build/brief.log
node scripts/build.mjs dist                     # release distribution in build/dist/<macos|linux|windows>/
node scripts/build.mjs --help                   # the commands and options (run.mjs --help too)
dub build --compiler=ldc2                       # the same build without the script; dub test likewise
node --test "tests/js/*.test.mjs"               # JS unit tests only (pure modules such as resources/new-tab.js)
node scripts/utils/i18n-extract.mjs             # brings the translation catalogs up to the texts of the code
node scripts/utils/screenshot.mjs --open <log>  # the app's window with a log → build/screenshot.png (--help)
node scripts/utils/app.mjs start --open <log>   # a running copy (debug; --release too) to drive: eval, wait, shot, run, stop (--help)
node scripts/build.mjs gen-log <file> --format dlt|dlt-v2|text --size 1G  # a test log, same bytes per seed (--help)
node scripts/build.mjs pack-libs                # the Sciter libraries of libs/ into their archives of LFS, after an update
node scripts/build.mjs bench [log] [words] --against master  # bench_rows.d (--bench index) of both sides, a table (--help)
node scripts/utils/check-ai-context.mjs         # names in backquotes of .ai/, AGENTS.md, .claude/ the code no longer has
node scripts/utils/backtrace.mjs [pid]          # stacks of every thread of a running (hung) app → build/backtrace-<pid>.txt
```

- `dub.sdl` puts every build in `build/<platform>-<arch>-<build type>/` (`osx-aarch64-unittest`
  for `dub test`) and copies the Sciter library of `libs/` next to it (`copyFiles`): a build
  runs from there, in a fresh worktree too. `libs/` keeps each library packed by brotli
  (`<library>.br`) in Git LFS and a clone fetches none of them (`.lfsconfig`):
  `scripts/build.mjs` fetches the one archive a build needs and unpacks it next to itself
  (ignored by git), while a plain `dub build` on a fresh clone finds no library. The Sciter version is in `libs/SCITER_VERSION`; the app's version is `VERSION`.
- `dub test` runs unit-threaded's runner (`dub.sdl`, configuration `unittest`, one thread):
  every `unittest` block is a test of its own, named by its `@("...")` string, and the ones
  after a failed one still run. `test --module` compiles one module and what it imports with
  the flags of `dub.sdl` and druntime's runner: no filter, a module stops at its first failing
  `unittest`.
- Keep the `-preview=in/dip1000/dtorfields` flags of `dub.sdl` when compiling by hand.
- The files of `resources/` are built into the executable: a JS/CSS/HTML change needs a
  rebuild, a new file is added to `ui/app_resources`.
- `settings.json` sits next to the executable and is rewritten on exit: every build folder has
  its own. Only `dist` builds the installed program (dub's build type `dist`,
  `version (Installed)`), which keeps it in the user's folder. Run a copy of the binary from another folder to keep the developer's own settings.
  A release build runs one copy per `settings.json`; debug builds run side by side.
- The script's `console.log` goes to the app's stdout as `info [script]: ...` lines.

## Packages

A package imports only the packages to its left (unittests may import more):

```
utils  ←  log_core  ←  formats  ←  domain  ←  ui  ←  app.d
utils  ←  sciter  ←  ui
ptable  ←  ptable_text  ←  ui     (ptable imports only std: a package of its own; ptable_text, the text columns, only ptable and std)
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
