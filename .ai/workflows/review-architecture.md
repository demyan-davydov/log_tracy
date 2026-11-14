# Review Lens: Architecture

Scope and report: `.ai/workflows/review.md`. The question: does the change put each
responsibility where it belongs, go through the extension points the repository already has,
keep its contracts, and is it no more complex than the problem needs?

This lens takes a diff or a **plan** of a feature (a file or the text of the task). On a plan
it is cheapest: a responsibility in the wrong place found after the code is a rework. On a
diff, say for each finding whether it is **local** (a move or a rename within the change) or a
**rework** (a design to change), so the author can weigh it.

## What to Read

- `.ai/knowledge/architecture.md` (all of it: data flow, packages, script ↔ backend, threads,
  the "start here" map), then the knowledge files of the areas touched
  (`.ai/knowledge/INDEX.md`).
- The story of the feature (`docs/stories/<feature>.md`) and the commit messages, when there
  are: what was decided on purpose is not a finding unless it breaks a rule or a contract.
- For each new type or function: where its neighbours live, who will call it, and whether
  something like it exists already (grep before claiming it doesn't).

## Red Flag: Knowledge of a Format Outside It

`domain/` and `ui/` know formats only through `LogFormat`, `detectFormat` and the registry. A
cast to a concrete format, a format name or id compared, a column of one format handled by
name in the table code: the next format will need the same `if`. The fix is a member or a
declaration of `LogFormat` (`ColumnInfo`, a capability), not another branch.

## Red Flag: Logic Where It Can't Be Tested

Decisions in `MainWindow`, in an `xcall` case, in DOM code of the script or in Sciter
callbacks, instead of a Sciter-free module (`ui/app_session` and its helpers, the state
machines, a pure `resources/*.js` module with a test in `tests/js`). A branch that decides what
the user sees and has no test because it sits in the window is reported.

## Red Flag: A Second Way Past an Extension Point

The repository has one way for each of these; a change that adds a parallel one is reported:

- a format: a module and its entry in `formats/registry` (`.ai/workflows/add-format.md`);
- a call of the script to the backend: a function of `resources/backend.js` → `MainWindow`
  `xcall` → `AppSession` (`.ai/workflows/add-backend-call.md`); Sciter's services only through
  `resources/platform.js`;
- the backend telling the script: a queued `callScript`, sent by `onIdle()`, never from inside
  an `xcall` or another thread;
- background work: an operation of the `LogIndex` `BackgroundSlot`, reported as events of its
  bus; a parallel scan through `utils/parallel_scan`; the read of the descriptions of a
  document (a FIBEX) on the second slot of `LogDocument`, its end an event of the same bus;
- a status of a view: the state machines on `utils/fsm` (`ui/main_view_fsm`,
  `ui/search_view_fsm`), not flags spread over the window;
- a request of the debug channel: a request kind of `ui/debug_protocol`, not a hook in the
  window or the session;
- a setting: the settings model (`ui/app_settings`) and its section, written by `onIdle()`.

## Checklist

1. **Where each responsibility lives.** By the package rules of `architecture.md`: `utils/`
   knows nothing of logs, `log_core/` nothing of a concrete format, `domain/` nothing of the
   window, `ui/` keeps Sciter at its edge. Legal imports are not enough: a module of the right
   package can still do the job of another (the session formatting cells, a filter knowing the
   table). A module that grew a second responsibility its `//!` comment doesn't state is a
   finding.
2. **Contracts kept** (`architecture.md`): index entries never move; `scanRecords` resumable,
   leaving an incomplete last record; script calls queued and sent after the document events;
   the debug channel known only to `main()`; settings written on idle and on exit. A change
   that bends one says so and why, or it is a finding.
3. **Coupling.** A new dependency between modules that didn't know each other, data threaded
   through layers that only pass it on, a new global or module-level state, a callback that
   ties two modules both ways, the script holding a copy of backend state it could ask for.
4. **The simpler way.** Something that already does this (a helper of `utils/`, an existing
   module, a script module): reuse it instead of a second copy. An abstraction with one
   implementation and no second one named in the plan or the backlog, options nobody sets,
   a layer that only forwards: smaller is better. The reverse is a finding too: a third copy
   of the same code that asks for a shared function.
5. **The change fits the direction of the project:** streaming sources later (`scanRecords`),
   more formats through the registry, Windows and Linux beside macOS (nothing macOS-only
   outside the platform modules and `platform.js`), logs of a gigabyte (nothing that assumes
   the whole log or all its records in memory).
6. **The knowledge still tells the truth:** after the change, `.ai/knowledge/architecture.md`
   and the knowledge file of the area describe what the code does (a moved responsibility, a
   new extension point, a new contract). Whether the file was touched at all is the rules
   lens; whether what it says is now false is this one.

## Not This Lens

The letter of the rules (naming, comments, i18n, tests present), the cost per record and the
races between threads, the look and behaviour for the user: other lenses. A design choice the
story explains and no rule or contract forbids is not a finding; a doubt about it is a question
for the author, said as one.
