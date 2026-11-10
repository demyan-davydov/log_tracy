# Architecture

## Data Flow

From bytes to the table:

```
ByteSource (log_core/byte_source)          bytes of a log, addressed by offset (FileSource = mmap)
  └ LogFormat (log_core/log_format)        splits bytes into records, decodes one into a LogMessage,
       │                                   declares the table columns (ColumnInfo)
       ├ DltFormat (formats/dlt/format)    binary DLT; parser in formats/dlt/parser
       └ TextFormat (log_core/text/...)    line-based base: multiline records, record length limit
            └ formats/*                    PlainTextFormat (fallback), LogcatFormat, ...
LogIndex (domain/log_index)                offset/filter/search indexes, built on a background thread
LogDocument (domain/log_document)          a log + its main view and search view, operation events
Workspace (domain/workspace)               open documents, the current one
AppSession (ui/app_session)                what the calls of the script do: files, tabs, views,
                                           search, filters, settings (Sciter-free, tested)
MainWindow (ui/main_window)                Sciter window: xcall bridge to the session, table rows
resources/script.js, tabs.js               the window: tabs, placeholder, settings, backend callbacks
resources/document-pane.js                 a panel per document (filters, tables, search)
resources/virtual-dlt-view.js              virtual table built from the column schema
```

## Packages

A package imports only the packages to its left (unittests may import more, e.g. a format to
build test data):

```
utils  ←  log_core  ←  formats  ←  domain  ←  ui  ←  app.d
utils  ←  sciter  ←  ui
```

- `utils/`: what knows nothing of logs and could move to another project as it is: chunked
  array, mapped file, lock guard, background slot, state machines (`utils/fsm`), event buses
  (`utils/event_bus/`), parallel scan, single instance, `ui_text`, substrings in any case
  (`utils/text_search`), regular expressions (`utils/text_regex`, the only module that uses
  `std.regex`), keys by name (`utils/keys`,
  whatever the system) and their codes of macOS (`utils/mac_keys`), Objective-C calls
  (`utils/objc`).
- `log_core/`: what doesn't depend on a format (LogMessage, LogFormat, filters, ByteSource,
  column layout); `log_core/text/` the base of the text formats.
- `formats/`: every format, one module (`formats/logcat.d`) or a package when it has several
  (`formats/dlt/`, `formats/can/`, `formats/syslog/`). `formats/registry.d` lists them.
  `formats/generator/` is not a format: the test log generator, compiled only for the
  unittests and the `gen_log` tool (`.ai/knowledge/formats.md`, The Log Generator).
- `domain/`: documents, indexes, anchors. Knows formats only through `LogFormat` and
  `detectFormat`.
- `sciter/`: the D wrapper over Sciter (window, application, value, ...); `sciter/capi/` the C
  API it calls.
- `ui/`: the window and the logic behind it; the Sciter-free part of it is unit-tested.
- `scripts/`: the build script (`build.mjs`: build, test (`--module` for one D module), dist,
  Windows check, `gen-log` that builds and runs the test log generator `gen_log.d`, `bench`
  that measures the tree against a ref, its pure part in `bench.mjs`), `run.mjs`,
  `check-ai-context.mjs` (the names of `.ai/` the code lost), `backtrace.mjs` (the stacks of
  a running app),
  `app.mjs` (drives a copy of the app through the debug channel), `screenshot.mjs`,
  i18n extraction, benchmarks (`bench_rows.d`, `bench_index.d`). They run from the project
  root wherever they are called from (`gen-log` runs the generator in the caller's folder:
  the path of a log is the user's). The pure part of `build.mjs` is tested by
  `tests/js/build-script.test.mjs`; Linux and Windows `dist` were not tried on those systems
  yet (`docs/backlog.md`).

## Script ↔ Backend

- The script asks the backend through `resources/backend.js`, one function per
  `Window.this.xcall(name, ...)`, read in `MainWindow.handleEvent` and done by `AppSession`.
  A new call gets its function there; the script calls nothing else
  (`.ai/workflows/add-backend-call.md`).
- The backend tells the script what changed by `callScript` of a global function
  (`onMainViewChanged(docId, json)`, `onSearchViewChanged`, `onDocumentOpened`, ...). The
  session only queues those calls; `MainWindow.onIdle()` sends them (`takeScriptCalls`) after
  the document events of the indexing thread were dispatched on the UI thread, never from
  inside an `xcall`.
- The resources are built into the executable (`ui/app_resources`, string imports) and served
  to Sciter at `this://app/<path>` (`SciterWindow.onLoadData`). The icons are not built in.
- The script's `console.log` goes to the app's stdout as `info [script]: ...` lines (errors as
  `error [script]: ...`), next to the backend's `writeln`.

## Settings and Lifetime

- `settings.json` sits next to the executable and is rewritten on exit. Run a copy of the
  binary from another folder to keep the developer's own settings.
- The settings are only marked changed: the next `onIdle()` writes them (`settingsDue`), with
  the script's `getAppState()` merged in. `saveAppState` on closing writes them at once; from
  then on the script is not called any more (its view is being torn down), and what changes
  after that is written on exit (`finish`).
- On macOS Quit (Cmd+Q, the Dock, logging out) closes the window without `closerequest` and
  exits inside the event loop: the application delegate's `applicationShouldTerminate:`
  (`ui/main_menu_loader`) writes the settings first (`MainWindow.terminate`).
- The window frame is written when the user is done moving or resizing it
  (`replacementend`) and restored by the script (`resources/window-frame.js`): `main.htm`
  sizes the window, not the creation rect.
- A release build runs one copy per `settings.json` (`utils/single_instance`, a lock on
  `settings.lock` next to it): a second one brings the first forward and exits. Debug builds
  run side by side.
- A recent file (`ui/recent_files`) keeps its format choice and its filter sets.
- `main()` (`app.d`) puts the application together: it makes the `AppSession` with its
  factory of documents (`LogDocument`), so `ui/` doesn't create documents itself, and gives it
  to `MainWindow`.
- Environment variables for trying things, read in `main()` (`newSession` of `app.d`) and
  passed to the session and the window: `OPEN_AT_START` (logs opened at start, `backend.startFiles()`), `MENU_BAR_PLATFORM`,
  `PSEUDO_LOCALE`, `SCITER_DEBUG_MODE` (the debug mode of Sciter, for its inspector). The table of them: `docs/building.md`, "Environment variables for
  development"; a new one goes there.
- The debug channel (debug builds only, `SCITER_DEBUG_PORT`): `ui/debug_channel` is a TCP
  server on 127.0.0.1 that runs the requests of `ui/debug_protocol` (JavaScript to evaluate,
  `resources/debug-eval.js` making its value plain JSON; a render of the window into a PNG,
  and of each open popup into a PNG beside it; the mouse moved and keys pressed as events of
  the system) on the window's thread through `postToWindowThread`, `evalInWindow`,
  `sendMouseMove` and `sendKeyPress` (`sciter/window`: `SciterPostCallback`, `SciterEval`,
  `NSEvent` on macOS with the codes of `utils/mac_keys`). The parsing of every request (a
  key's name by `utils/keys`), the order of the events handed (`sendInput`) and the response
  lines are in `ui/debug_protocol` only: `debug-eval.js` gives the value or what was thrown,
  not a line of the protocol; the channel only runs things on the window's thread.
  Kept apart on purpose: `main()` starts and stops it, nothing else knows of it; a new command
  is a request kind of the protocol, not a hook in the window or the session: a member of
  `RequestKind` with its parsing, script and response in `ui/debug_protocol`, and its case of
  the `final switch` of `Server.answer` in `ui/debug_channel` (the compiler asks for it). Its
  client is `scripts/app.mjs`.

## Indexing and Threads

- `LogIndex` runs one operation at a time in a `BackgroundSlot`: build the offset, filter or
  search index. Progress and finish are reported as events on an `EventBusAsync`;
  `Document.dispatchEvents()` delivers them on the UI thread.
- The filter and search indexes are built in parallel blocks on `std.parallelism`'s task pool
  (`utils/parallel_scan`), appended in order as the blocks before them are done; the offset
  index is built sequentially. A format and a filter are called from several threads. A block
  checks a cancel, a lost file and the stop of the scan (`ScanStop`: a failed delivery)
  every `LogIndex.stopCheckRecords` records. The index grows block by block while the scan
  runs: keep it so, the results are meant to be shown before the scan ends.
- The indexes are `BaseIndex` over `utils/chunked_array` (`domain/index/`):
  - they grow by 64K-entry chunks (mmap / VirtualAlloc) up to 2^32 entries;
  - entries never move, which is what lets the indexing thread read the offset index without
    the mutex while the UI thread reads under it.
- `scanRecords` can resume and leaves an incomplete last record for a later call: this is meant
  for future streaming sources (growing file, serial port), so keep that contract.
- The view status shown to the user comes from the state machines `ui/main_view_fsm` and
  `ui/search_view_fsm` (on `utils/fsm`), free of Sciter so they can be unit-tested.

## If You Need X, Start Here (backend)

- Opening a file, tabs, views, search, settings as the script sees them: `ui/app_session`
- The xcall dispatch, table rows as Sciter values: `ui/main_window`, `ui/table_rows`
- Columns of the table for a document: `ui/table_columns`, `log_core/column_layout`
- Settings model and recent files: `ui/app_settings`, `ui/recent_files`
- Filter panel commands: `ui/filter_commands`; search chips: `ui/search_chips`
- The menu: `ui/app_menu` (model), `ui/main_menu_loader` (native macOS)
- Indexes and background work: `domain/log_index`, `domain/index/`, `utils/background_slot`,
  `utils/parallel_scan`
- A document and its views, anchors: `domain/log_document`, `domain/document`,
  `domain/anchors`
- Formats and detection: `formats/registry` (see `.ai/knowledge/formats.md`)
- Backend texts for the user: `utils/ui_text`, `ui/translations` (see `.ai/knowledge/i18n.md`)
- Looking inside the running app (debug builds): `ui/debug_channel`, `ui/debug_protocol`,
  `resources/debug-eval.js`, the client `scripts/app.mjs` (`.ai/workflows/preview-ui.md`)
