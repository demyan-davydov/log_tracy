# D Rules

## Scope

Applies to all D code in `source/` and `scripts/*.d`.

## Build

- Build and test with ldc2. Keep the `-preview=in/dip1000/dtorfields` flags of `dub.sdl`
  when compiling by hand.

## Structure

- A package imports only the packages to its left (the order and what each package holds:
  `.ai/knowledge/architecture.md`, Packages). Unittests may import more.
- UI command logic that needs testing goes into Sciter-free modules (`ui/app_session`,
  `ui/filter_commands`), not into `MainWindow`: a new xcall is a method of the session, the
  window only reads its parameters and answers.
- Use camelCase.
- A class has one responsibility. About five fields is normal for a class, seven is the limit and needs a
  strong reason; a struct that only carries data out (a context, a record) is not counted. More fields, a
  constructor of more than four parameters or a file past ~600 lines of code mean several classes in one:
  take out the state that goes together with
  its rules (the columns, a press of the mouse, the selection, the copy) into a unit of its own that is
  tested alone, and give the host's objects to a constructor as one struct (`TablePorts`). A new
  responsibility is not added to a big class: it gets a unit, and the big class only calls it.

## Red Flag: `out LogMessage`

Pass a `LogMessage` by `ref`, never `out`: `out` resets it to `.init` without its destructor
and leaks the buffer on every decode.

## Red Flag: Allocation or Mutable State in Decoding

Decoding a record allocates nothing (one reused buffer per `LogMessage`). A format instance is
immutable after creation: the UI thread and the indexing threads call it concurrently.

## Red Flag: Matching User-Facing Text

Never match, parse or compare text meant for the user (error messages, labels). A text for the
user made by the backend is a `uiText` template thrown in a `UiTextException`; carry what
logic needs in types.

## Known Traps

- `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12, even in release
  builds: check the month first.
- UFCS accessors (e.g. `formats/dlt/fields`) don't work through a pointer.
- Phobos auto-decodes narrow strings: `canFind` on `wchar[]` decodes to `dchar`. On hot paths
  compare code units.
- Never change a format's `id`: settings refer to it.
- `scanRecords` must keep resuming and leaving an incomplete last record for a later call.
- A pointer `in` gives into a map (built-in AA or `ptable/memory` `HashMap`) is not valid after anything adds to the map:
  it may grow and move its slots. Copy the value out first (`RowCache.entry`: a segfault on a long drag up, 2026-11-18).
