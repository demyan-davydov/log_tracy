# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

DLT Explorer: a desktop viewer for DLT and text logs (macOS, Linux, Windows), written in D with
the Sciter UI framework through its own minimal binding (`source/sciter`, `source/sciter_wrapper`).
The UI is vanilla HTML/CSS/JS in `resources/`, not Reactor style. Files can be ~1 GB: nothing
loads a whole log into memory.

## Commands

Build and test with **ldc2** (`--compiler=ldc2`); the scripts assume it too.

```sh
dub build --compiler=ldc2          # builds ./dlt_explorer
dub test --compiler=ldc2           # all D unittests ("N modules passed unittests")
node --test tests/js               # JS unit tests (pure modules such as resources/new-tab.js)
./check-windows-compile.sh         # from macOS/Linux: cross-compiles app + unittests for Windows x64, no link
test-windows.bat                   # on Windows: build + unittests
```

- The druntime test runner has no filter, and it stops a module's tests at the first failing
  `unittest` block. To run the tests of one module that doesn't depend on Sciter, compile it on
  its own:
  `ldc2 -unittest -main -i -preview=in -preview=dip1000 -preview=dtorfields -Isource source/log_core/text/text_format.d -of=/tmp/t && /tmp/t`
- Keep the `-preview=in/dip1000/dtorfields` flags of `dub.sdl` when compiling by hand.
- Running the app:
  - `resources/` is read from disk at run time, so a JS/CSS/HTML change needs a restart, not a
    rebuild.
  - `libsciter.dylib` (or `sciter.dll`) must sit next to the executable.
  - `settings.json` sits next to the executable and is rewritten on exit. Run a copy of the binary
    from another folder to keep the developer's own settings.

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
MainWindow (ui/main_window)                Sciter window: xcall bridge to the script
resources/script.js, virtual-dlt-view.js   tabs, panels, virtual table built from the column schema
```

### Where things live
- `log_core/` holds what doesn't depend on a format (LogMessage, LogFormat, filters,
  ByteSource), `log_core/text/` the base of the text formats.
- Every format lives in `formats/`: one module (`formats/logcat.d`), or a package when it has
  several (`formats/dlt/`, `formats/can/`, `formats/syslog/`). `formats/registry.d` lists them.
- `domain/` (documents, indexes) knows formats only through `LogFormat` and `detectFormat`.

### Formats and detection
- The formats supported now and the ones planned: `docs/formats.md`. Keep it up to date
  when a format or a variant is added.
- `formats/registry.detectFormat` asks every `FormatDetector` for a score on the first
  64 KB and picks the best.
- Plain text is the low-score fallback; data no detector accepts is refused.
- A `.dlt` extension alone only decides for binary data.
- A format instance is created per document (it may hold a variant) and must stay immutable:
  the UI thread and the indexing thread call it concurrently.

### Adding a text format
Derive from `TextFormat` and implement `decodeText`, `columns` and `name`. Implement
`isRecordStart` too if continuation lines are glued to their record. Add a `FormatDetector` and
register it in `formats/registry`. Parsing helpers (numbers, times, dates) live in
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
- Filters implement `LogFilter!wchar` (`log_core/log_filter`):
  - **`FieldFilter`** (`log_core/field_filter`) is the quick filter. It is built from the column
    schema and a `{column id: value}` map.
  - **`DltLogFilter`** reads `.dlf` files and only applies to DLT documents
    (`DltLogFilter.canFilter`).

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
- The table columns, the row cells (`asSciterRow` in `main_window`) and the quick filter panel
  are all built from the format's `ColumnInfo` schema, fetched by the script with
  `xcall("getColumns")`.
- A row is: anchored, filterMask, view index, message index, level, then one cell per column.
  - A time cell is `[microseconds, TimeKind]`: it is shown by the kind of the record, not of
    the column.
  - Hex cells are formatted by the backend: 64-bit values don't fit a script number.
  - The level colors the cells of columns with `ColumnInfo.byLevel` (an HTTP status shown as
    it is).
  - How a cell shows its value lives in the Sciter-free `resources/cell-format.js`, tested
    by `tests/js`.
- Per-document UI state lives in `Map`s keyed by document id in `script.js` (search drafts,
  quick filter values, scroll/selection).
- The view status shown to the user comes from the state machines `ui/main_view_fsm` and
  `ui/search_view_fsm` (on `source/fsm`). They are kept free of Sciter so they can be unit-tested.
- UI command logic that needs testing goes into Sciter-free modules (e.g. `ui/filter_commands`),
  not into `MainWindow`.

## Conventions

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
