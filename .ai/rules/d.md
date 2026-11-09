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
