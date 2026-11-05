# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DLT Explorer: a desktop viewer for DLT and text logs (macOS, Linux, Windows), written in D with
the Sciter UI framework through its own minimal binding (`source/sciter`: the C API in `sciter/capi`, the D wrapper over it).
The UI is vanilla HTML/CSS/JS in `resources/`, not Reactor style. Files can be ~1 GB: nothing
loads a whole log into memory.

## Commands

Build and test with **ldc2** (`--compiler=ldc2`); the scripts assume it too.

```sh
dub build --compiler=ldc2          # builds ./dlt_explorer
dub test --compiler=ldc2           # all D unittests ("N modules passed unittests")
node --test tests/js               # JS unit tests (pure modules such as resources/new-tab.js)
scripts/check-windows-compile.sh   # from macOS/Linux: cross-compiles app + unittests for Windows x64, no link
scripts\test-windows.bat           # on Windows: build + unittests
```

- The druntime test runner has no filter, and it stops a module's tests at the first failing
  `unittest` block. To run the tests of one module that doesn't depend on Sciter, compile it on
  its own:
  `ldc2 -unittest -main -i -preview=in -preview=dip1000 -preview=dtorfields -Isource source/log_core/text/text_format.d -of=/tmp/t && /tmp/t`
- Keep the `-preview=in/dip1000/dtorfields` flags of `dub.sdl` when compiling by hand.
- Running the app:
  - `resources/` is read from disk at run time, so a JS/CSS/HTML change needs a restart, not a
    rebuild.
  - `libsciter.dylib` (or `sciter.dll`) must sit next to the executable, and next to the test
    executable for `dub test` (in a fresh worktree too). The libraries of every platform are in
    `libs/`; the bundle scripts take them from there.
  - `settings.json` sits next to the executable and is rewritten on exit. Run a copy of the binary
    from another folder to keep the developer's own settings.
  - The script's `console.log` goes to the app's stdout as `info [script]: ...` lines (errors as
    `error [script]: ...`), next to the backend's `writeln`.

## Architecture

Data flows from bytes to the table like this:

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
resources/script.js, document-pane.js     tabs; a panel per document (filters, tables, search)
resources/virtual-dlt-view.js              virtual table built from the column schema
```

The script asks the backend through `Window.this.xcall(name, ...)` (read in
`MainWindow.handleEvent`, done by `AppSession`); the backend tells the script what changed by
`callScript` of a global function (`onMainViewChanged(docId, json)`, `onSearchViewChanged`,
`onDocumentOpened`, ...). The session only queues those calls; `MainWindow.onIdle()` sends them
(`takeScriptCalls`) after the document events of the indexing thread were dispatched on the UI
thread, never from inside an `xcall`. The settings are likewise only marked changed: the next
`onIdle()` writes them (`settingsDue`), with the script's `getAppState()` merged in.
`saveAppState` on closing writes them at once; from then on the script is not called any more
(its view is being torn down), and what changes after that is written on exit (`finish`).

### Where things live
A package imports only the packages to its left (unittests may import more, e.g. a format to build
test data):

```
utils  ←  log_core  ←  formats  ←  domain  ←  ui  ←  app.d
utils  ←  sciter  ←  ui
```

- `utils/` holds what knows nothing of logs and could move to another project as it is:
  chunked array, mapped file, lock guard, background slot, state machines (`utils/fsm`),
  event buses (`utils/event_bus/`).
- `log_core/` holds what doesn't depend on a format (LogMessage, LogFormat, filters,
  ByteSource), `log_core/text/` the base of the text formats.
- Every format lives in `formats/`: one module (`formats/logcat.d`), or a package when it has
  several (`formats/dlt/`, `formats/can/`, `formats/syslog/`). `formats/registry.d` lists them.
- `domain/` (documents, indexes) knows formats only through `LogFormat` and `detectFormat`.
- `sciter/` is the D wrapper over Sciter (window, application, value, ...), `sciter/capi/` the
  C API it calls.
- `ui/` is the window and the logic behind it; the Sciter-free part of it is unit-tested.
- `scripts/` holds the build, bundle and check scripts; they run from the project root
  wherever they are called from.

### Formats and detection
- The formats supported now and the ones planned: `docs/formats.md`. Keep it up to date
  when a format or a variant is added.
- `formats/registry.detectFormat` asks every `FormatDetector` for a score on the first
  64 KB and picks the best.
- Plain text is the low-score fallback; data no detector accepts is refused.
- A `.dlt` extension alone only decides for binary data.
- A recent file remembers the format it was opened with (`FormatChoice`: `FormatInfo.id` and
  the variant) and opens in it again through `createFormat`, without detection; a file with no
  saved format, or one this build can't create (unknown id, invalid variant), is detected. Never change a format's `id`: settings refer to it.
- A format instance is created per document (it may hold a variant) and must stay immutable:
  the UI thread and the indexing thread call it concurrently.

### Adding a text format
Derive from `TextFormat` and implement `decodeText`, `columns` and `name` (a line it can't
parse goes to the payload as it is: `decodeAsPlainText`). Implement
`isRecordStart` too if continuation lines are glued to their record. Add a `FormatDetector` and
register it in `formats/registry`. Declare the format's `FormatInfo` (stable `id`, `name`, a
three-letter `shortName` for the badge of a recent file) and return it from the detector's `info`. Parsing helpers (numbers, times, dates) live in
`log_core/text/text_parsing`.

### LogMessage and LogFilter
- `LogMessage!wchar` (`log_core/log_message`) is the format-neutral record:
  - a core: `timeNs` with its `TimeKind`, `level`, `payload`;
  - up to 8 fields by index, each a text or a number, with `hasField` telling whether the record
    has it.
- All texts live in one reused buffer whose size is derived from `maxRecordLength`, so decoding
  allocates nothing.
- Pass a `LogMessage` by `ref`, never `out`: `out` resets it to `.init` without its destructor
  and leaks the buffer on every decode.
- DLT fields are read through UFCS accessors in `formats/dlt/fields` (`msg.ecuId`, `msg.appId`, ...).
- DLT records for unittests are built by `formats/dlt/testing_utils` (`BuildV1`, `BuildV2`,
  `buildDltMessage`), also for the tests of other packages.
- Filters implement `LogFilter!wchar` (`log_core/log_filter`).
- The filters of the main view are rules, as in dlt-viewer, the same for every format
  (`log_core/rule_filter`):
  - a `FilterRule` (include / exclude / marker) is a set of `Condition`s on **column ids** of the
    format; a condition on a column the log doesn't have makes the rule "not applied"
    (`ruleError`), it is kept, never dropped silently;
  - a `FilterSet` is what one filter file holds; `RuleFilter.compile` builds the view filter from
    the enabled rules of the enabled sets (shown: an include rule matches, or there is none, and
    no exclude rule does; markers don't filter);
  - a rule has a `RuleId` while its document is open (given by `DocumentFilters`, not saved);
    `RuleMatcher` finds the first rule *with a color* a record matches, of any kind, as dlt-viewer
    colors the rows. It runs for every row shown on the UI thread: keep matching cheap (the
    conditions of a rule are checked cheapest first, substrings by code units).
- Filter files: our own JSON format (`log_core/filter_file`, `<name>.<format id>.logfilter`, the
  format is also written inside) for any log; a `.dlf` of dlt-viewer (`formats/dlt/dlf`) for DLT
  logs only, converted to rules and back (`fromDlf`, `toDlf`), naming what is lost.
- `ui/filter_commands.DocumentFilters` holds the sets of a document and the panel commands. A set
  is a **copy**: a loaded file is copied into the settings of the log (`RecentFile.filters`, rules
  as in a filter file), edits are remembered at once, and a set can be exported. No file is
  referred to, so a file loaded for two logs doesn't tie them together.
- The rule editor (`resources/rule-editor.htm`) has a row per column of the format; the mapping
  of conditions to rows is the Sciter-free `resources/rule-form.js`, tested by `tests/js`.

### Indexing and threads
- `LogIndex` runs one operation at a time in a `BackgroundSlot`: build the offset, filter or
  search index. Progress and finish are reported as events on an `EventBusAsync`;
  `Document.dispatchEvents()` delivers them on the UI thread.
- The indexes are `BaseIndex` over `utils/chunked_array`:
  - they grow by 64K-entry chunks (mmap / VirtualAlloc) up to 2^32 entries;
  - entries never move, which is what lets the indexing thread read the offset index without
    the mutex while the UI thread reads under it.
- `scanRecords` can resume and leaves an incomplete last record for a later call: this is meant
  for future streaming sources (growing file, serial port), so keep that contract.

### UI side
- The table columns and the row cells (`asSciterRow` in `main_window`) are built from the
  format's `ColumnInfo` schema as the user's layout of that format arranges it
  (`log_core/column_layout`, `AppSettings.columnLayouts` by format id, edited in the Columns
  section of Settings): `xcall("getTableColumns", docId)`, arranged once per format and variant
  (`ui/table_columns`). The rule editor gets all the columns of the format:
  `xcall("getColumns", docId)`.
  - Index (not a format column) stays first and Payload last; the others can be moved and
    hidden. A layout is one per format id, for all its variants: `formats/registry.formatColumns`
    gives the columns of all of them.
  - Dragging to reorder (tabs, columns in Settings) shares `resources/drag-strip.js` (the
    elements: shifts, classes, marker) over the Sciter-free `resources/drag-order.js` (the math).
- A row is: anchored, rule id, view index, message index, level, then one cell per column
  (`rowLayout` in `resources/cell-format.js`). A row of the search results (`getSearchViewItem`
  only) has one more cell after the columns: what the chips of the search found in the payload,
  `[[start, end, chip]]` in UTF-16 units (`SearchFilter.matchRanges`), shown in the chips' match
  colors; main view rows don't have it and compute nothing.
  - The rule id is the first rule with a color the record matches (null if none); the script
    looks its color up in the rules of the panel (`resources/rule-colors.js`) and sets it on the
    row, `table.css` shows it on the Index cell only, as a fade from the left edge.
  - A time cell is `[microseconds, TimeKind]`: it is shown by the kind of the record, not of
    the column.
  - Hex cells are formatted by the backend: 64-bit values don't fit a script number.
  - The level colors the cells of columns with `ColumnInfo.byLevel` (an HTTP status shown as
    it is).
  - How a cell shows its value lives in the Sciter-free `resources/cell-format.js`, tested
    by `tests/js`.
- Every open document has its own panel, `DocumentPane` (`resources/document-pane.js`): the
  filters of the sidebar, both tables, the search editor, and the state behind them. Only the
  panel of the active tab is shown, the others are `display: none` and keep their rows, scroll,
  selection and draft as they are; a hidden panel renders what changed when it is shown.
  `script.js` keeps the tabs, the placeholder and the settings.
  - The calls of a document's views, filters and search take its id first
    (`getMainViewItem(docId, index)`, ...); only the menu and Settings use the active document.
  - The sizes of the splitters follow from the panel shown before.
  - Never hide a log table itself: one hidden by `display: none` before it was ever laid out
    keeps its cells 1px wide for good (Sciter). Status views cover it instead
    (`.status-view.overlay`).
  - What a table does on a change of its view is the Sciter-free `resources/pane-state.js`.
- The view status shown to the user comes from the state machines `ui/main_view_fsm` and
  `ui/search_view_fsm` (on `utils/fsm`). They are kept free of Sciter so they can be unit-tested.
- UI command logic that needs testing goes into Sciter-free modules (`ui/app_session`,
  `ui/filter_commands`), not into `MainWindow`: a new xcall is a method of the session, the
  window only reads its parameters and answers.

## Conventions

- The main branch is `master`. Work goes on a branch and is merged with `--no-ff`. The story of
  a feature (what and why, in Russian) is in `docs/stories/`; what was noticed but left for
  later goes to `docs/backlog.md`.
- Every module starts with a `//!` comment stating its responsibility. Use camelCase, write
  comments in English.
- Tests first: write the test, see it fail for the right reason, then change the code. For new
  code start from a compiling stub so the test fails at run time.
- Commit subjects are short, lower-case and imperative ("grow the indexes by chunks instead of ...").
- Known traps:
  - `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12, even in release
    builds: check the month first.
  - Sciter `Element.append` takes a single node.
  - Setting an input's `value` attribute in JSX doesn't change its current value: assign
    `input.value`.
  - UFCS accessors don't work through a pointer.
