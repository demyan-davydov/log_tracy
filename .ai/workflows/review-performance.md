# Review Lens: Performance and Threads

Scope and report: `.ai/workflows/review.md`. The question: is the change fast enough for a log
of a gigabyte (tens of millions of records), and safe across the threads that run at once?

## What to Read

- `.ai/knowledge/architecture.md` (Indexing and Threads), `.ai/rules/ui.md` (its Red Flags),
  `.ai/rules/d.md`, `docs/performance.md` (the measurements to compare with).
- The changed code and every caller of it: who calls it from which thread, and how often.

## The Threads

- **UI thread:** the Sciter window and its script, `MainWindow`, `AppSession`, the rows of the
  tables (the rows read from the document, the cells of their columns, rule matching, match ranges),
  `Document.dispatchEvents()` delivering the events of the indexing.
- **Indexing thread:** one pass at a time in the `BackgroundSlot` of a `LogIndex`
  (`runPass`): its stages (offset, filter, search index) take turns, each over the range it
  doesn't cover yet, so the operations the views see overlap; it reports on an
  `EventBusAsync`. The state of the stages is written by the UI thread only while no pass
  runs, and by the worker of a pass.
- **Task pool workers:** the blocks of a filter or search scan (`utils/parallel_scan`), each
  decoding records and matching them **at the same time** as the others.
- So a `LogFormat` and a `LogFilter` are called from several threads at once; the indexes are
  appended by one thread and read by another (entries never move: `utils/chunked_array`), under
  `LogIndex`'s mutex where it says so.

## Red Flag: Mutable State Shared Between Threads

- A field of a format or a filter written after construction (a cache, a reused buffer, a
  counter), a lazily initialized member: the scan blocks race on it. Per-call state lives in
  the caller's `LogMessage` or on the stack.
- `__gshared` or `shared` data written without atomics or a lock. D module-level and `static`
  variables are thread-local by default: a "global cache" there is silently one per thread.
- Reading what another thread writes without the order `LogIndex` relies on (an index entry
  read before it is published, a length read without the mutex where the writer holds it).
- A `std.regex` matcher or any object with internal state shared by the blocks.

## Red Flag: Blocking or Heavy Work on the UI Thread

- File I/O, a scan over the records, decoding more than the rows shown, sorting or building an
  index on the UI thread: the window freezes for the size of the log. It belongs in an
  operation of the indexing thread, reported back by events.
- Waiting on the indexing thread (a lock held by a long scan, a join) from the UI thread.
- Calling the script or Sciter from inside an `xcall` or from another thread (it goes through
  the queue that `onIdle()` sends).

## Red Flag: Heavy Work per Row

The per-row rules of `.ai/rules/ui.md`: a fast scroll renders many rows. Work that can be
skipped when nothing needs it (no rules, no search) is skipped; nothing allocates per row where
a reused buffer will do.

## Checklist

1. **Complexity against the size of the log.** Anything linear in the records runs in the
   background with progress and cancel; nothing quadratic; nothing that keeps a copy of all
   records or all payloads (the file is mapped, not loaded).
2. **Scan loops** (decode, filter, search): no allocation per record (the GC stops every
   thread, and the task pool makes that worse); no Phobos auto-decoding of `wchar[]`/`char[]`
   (`canFind`, `startsWith` on narrow strings decode to `dchar`); cheap checks first; a cancel
   and a lost file are checked as the existing loops do (every `stopCheckRecords` records of a block, `scanMatches` of `domain/index/match_scan`).
3. **Indexes:** they grow by chunks, entries never move; a change of an entry's layout keeps
   readers on the other thread safe. Memory per record: 8 bytes in the offset index is the
   budget; more per record is a decision to name.
4. **Locks:** held briefly, never around a scan or a callback; one order where two are taken;
   no lock taken on the UI thread that a scan holds for long.
5. **The table:** what it does per row and per frame (`ptable`, `ui/log_table`) stays O(the cells of the row on screen); it keeps no
   content of a row between frames and makes no garbage in a steady frame (a test); a change of one row repaints that row only.
6. **The cost is measured, not guessed,** when the change is on a hot path:
   `scripts/utils/bench_rows.d` (per-row work against decode), `scripts/utils/bench_index.d` (indexing),
   against `master` by `node scripts/build.mjs bench` (`--bench index`). A finding without a
   measurement is **suspected**.

## Not This Lens

The rules of the repository (other than the Red Flags above), the look and behaviour for the
user: other lenses.
