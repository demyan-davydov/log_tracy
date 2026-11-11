# Architecture

## Data Flow

From bytes to the table:

```
ByteSource (log_core/byte_source)          bytes of a log, addressed by offset (FileSource = mmap)
  └ LogFormat (log_core/log_format)        splits bytes into records, decodes one into a LogMessage,
       │                                   declares the table columns (ColumnInfo)
       ├ DltFormat (formats/dlt/format)    binary DLT; parser in formats/dlt/parser
       └ TextFormat (log_core/text/...)    line-based base: multiline records, record length limit,
            │                              UTF-16 through inEncoding (log_core/text_encoding)
            └ formats/*                    PlainTextFormat (fallback), LogcatFormat, ...
LogIndex (domain/log_index)                offset/filter/search indexes, built on a background thread
LogDocument (domain/log_document)          a log + its main view and search view, operation events
DocumentStore (domain/document_store)      open documents and who holds them, their events by id
AppSession (ui/app_session)                what the calls of the script do: files, tabs
                                           (ui/document_tabs), views, search, filters, settings
                                           (Sciter-free, tested)
MainWindow (ui/main_window)                Sciter window: xcall bridge to the session, table rows
resources/script.js, tabs.js               the window: tabs, placeholder, settings, backend callbacks
resources/document-pane.js                 a panel per document: its parts (view-table: the two tables,
                                           filter-panel, search-bar) and status-view
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
  column layout, the encodings of text: `text_encoding`); `log_core/text/` the base of the text formats.
- `formats/`: every format, one module (`formats/logcat.d`) or a package when it has several
  (`formats/dlt/`, `formats/can/`, `formats/syslog/`). `formats/registry.d` lists them.
  `formats/generator/` is not a format: the test log generator, compiled only for the
  unittests and the `gen_log` tool (`.ai/knowledge/formats.md`, The Log Generator).
- `domain/`: documents, indexes, anchors. Knows formats only through `LogFormat`,
  `detectFormat` and the interfaces a format may add, asked by a cast (`PartedFormat`).
- `sciter/`: the D wrapper over Sciter (window, application, value, ...); `sciter/capi/` the C
  API it calls.
- `ui/`: the window and the logic behind it; the Sciter-free part of it is unit-tested.
- `scripts/`: the build script (`build.mjs`: build, test (`--module` for one D module), dist,
  Windows check, `gen-log` that builds and runs the test log generator `gen_log.d`, `bench`
  that measures the tree against a ref, its pure part in `bench.mjs`; `--brief` filters the
  output of every step through `build-output-filter.mjs`), `run.mjs`,
  `check-ai-context.mjs` (the names of `.ai/` the code lost), `backtrace.mjs` (the stacks of
  a running app),
  `app.mjs` (drives a copy of the app through the debug channel), `screenshot.mjs`,
  i18n extraction, benchmarks (`bench_rows.d`, `bench_index.d`). They run from the project
  root wherever they are called from (`gen-log` runs the generator in the caller's folder:
  the path of a log is the user's). The pure part of `build.mjs` is tested by
  `tests/js/build-script.test.mjs`, the filter of `--brief` by `tests/js/build-output-filter.test.mjs`; Linux and Windows `dist` were not tried on those systems
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
- `main()` (`app.d`) puts the application together: it makes the `DocumentStore` and the
  `AppSession` over it with its factory of documents (`LogDocument`), so `ui/` doesn't create
  documents itself, gives the session to `MainWindow`, and closes the store after the window
  (on macOS Quit the loop never returns: `AppSession.terminate` closes the store then).
- A document lives while someone holds it (`DocumentStore.hold`/`release`; `add` holds it for
  the caller): a tab of the window (`AppSession`: a tab is a holder, `ui/document_tabs` the
  order and the active one), later an AI session. The last `release` closes it; closing a tab
  doesn't close a document another still holds. Ids are the store's, the tabs know only theirs.
  The views, filters, search and anchors of a document are its tab's: another holder only holds
  it and reads records. Only the window opens files yet, so every document has a tab (a tab for
  a document of another holder: `docs/backlog.md`).
  The store is of the UI thread: `add`, `hold`, `release` (its `destroy` cancels and joins the
  indexing), `doc` are called there, so a holder on another thread (the MCP core) hands its
  calls over to it. Its events are pumped by the window's idle loop
  (`AppSession.dispatchEvents`); a subscriber may release documents meanwhile. A holder keeps
  the id, not the `Document`: a Retry replaces the object for every holder, and takes
  `doc(id)` each time.
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

- `LogIndex` runs one pass at a time in a `BackgroundSlot` (`runPass`). A pass brings the
  indexes up to date, each over the range it doesn't cover yet: the offset index over the new
  bytes of the source, the filter index over the new records, the search index over the new
  rows of the main view; the stages take turns until none has anything left, a part at a time
  (`followRecords`) while another follows. A rebuild is the same pass from zero
  (`setViewFilter`, `setSearchFilter` clear and reset). A cancelled pass leaves what it did:
  a request that comes while one runs stops it and the next pass goes on, so a filter and a
  search asked for while the file loads run with the load. Don't add an operation that builds
  an index whole, apart from a pass.
- The operations the views see (`OperationStarted / Progress / Finished` of the load, the
  filter, the search) overlap. `LogDocument` tells them on the UI thread from the index's
  `StageFinished` and `PassFinished`; `OperationProgress` carries all of them in one event
  (events of one type override each other in the queue). `Document.dispatchEvents()` delivers
  the events on the UI thread. The load and the filter tell their end apart, as soon as they
  have nothing left: the file may be loaded while its filter still fills the main view (the
  main view machine goes on as `Filtering`, the same content). A failure is of a stage
  (`PassFinished.failed`): a filter or a search that fails leaves the file loading; a cancel
  names its operation (`Document.requestCancel(Operation)`).
- A source may grow (`ByteSource.complete` false: a file being written, a stream; its bytes
  don't move): a record cut by the end waits, `Document.dispatchEvents()` starts a pass when
  the index is `behind`, the views stay ready and `ContentGrown` tells them to count their
  rows. No such source exists yet (`docs/backlog.md`); tests use stand-ins.
- The filter and search indexes are built in parallel blocks on `std.parallelism`'s task pool
  (`utils/parallel_scan`), appended in order as the blocks before them are done; the offset
  index is built sequentially. A format and a filter are called from several threads. A block
  checks a cancel, a lost file and the stop of the scan (`ScanStop`: a failed delivery)
  every `stopCheckRecords` records (`domain/index/match_scan`). The index grows block by
  block while the scan runs: keep it so, the results are shown before the scan ends.
- `LogIndex` is the holder of its parts (`domain/index/`), which are not thread-safe: it owns
  the mutex, the worker and their lifetime. The parts:
  - `RecordStore` (`record_store`): the source, the format and the offset index, which only
    grows. A format that is a `PartedFormat` (`log_core/log_format`: its records may be
    numbered parts of one message) has its parts joined into one record as they are found
    (`part_joiner`): `findRecords` asks the format, without the lock, what each record is
    as a part; `append` holds the records from a first part on until its message is whole
    or can't be (`RecordStore.holding`), and the end of the data lets them out (a source
    may tell its end without more bytes: `LogIndex.behind` counts what is held then). A
    joined record has the joined bit of its `OffsetIndexItem` and the offsets of its other
    parts in a table of the store, which `Records.decode` reads. An `append` that fails
    halfway leaves the store refusing every later one. Its one promise across threads: the
    records below the length of a `Records` a reader was given are read by any number of
    threads while one writer appends after them. The holder gives a reader its `Records` (under the mutex, or by starting the thread or
    task that reads) and closes the store only once no scan reads it: `LogIndex` joins its
    worker first, and a scan returns only when its blocks are done. `close()` frees the
    offset index too: it is a class, and the GC doesn't see that memory;
  - `ViewIndexes` (`views`): the filter and search indexes, the rows of the two views;
  - `MatchStage` (`match_stage`): how far the filter or the search of a pass has got;
  - `scanMatches` (`match_scan`): the parallel scan of a range for the anchored and
    matching records, over `Records` only: what another reader of the records (a search
    of its own, apart from the views) scans with too;
  - `ProgressReporter` (`progress`).
- The indexes are `BaseIndex` over `utils/chunked_array` (`domain/index/`):
  - they grow by 64K-entry chunks (mmap / VirtualAlloc) up to 2^32 entries;
  - entries never move, which is what lets the indexing thread read the offset index without
    the mutex while the UI thread reads under it.
- `scanRecords` can resume and leaves an incomplete last record for a later call: this is meant
  for future streaming sources (growing file, serial port), so keep that contract.
- The view status shown to the user comes from the state machines `ui/main_view_fsm` and
  `ui/search_view_fsm` (on `utils/fsm`), free of Sciter so they can be unit-tested.
- A view shows its rows while an operation fills it. The contract is `dataVersion` of the
  view models: it changes when the content is replaced (a load, a filter, a search starts);
  under one version the content only grows, rows appended in order, none moved, so the table
  keeps its rows, scroll and selection and counts the new ones. The end of an operation keeps
  the version. The script grows a table on any view event of the same version, `ready` too:
  meant for sources that never end (story: `docs/stories/live-results.md`).

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
