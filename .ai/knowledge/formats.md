# Formats and Records

## Formats and Detection

- The formats supported now and the ones planned: `docs/formats.md`. Keep it up to date when
  a format or a variant is added.
- `formats/registry.detectFormat` asks every `FormatDetector` for a score on the first 64 KB
  and picks the best.
- Plain text is the low-score fallback; data no detector accepts is refused.
- A `.dlt` extension alone only decides for binary data.
- A recent file remembers the format it was opened with (`FormatChoice`: `FormatInfo.id` and
  the variant) and opens in it again through `createFormat`, without detection; a file with no
  saved format, or one this build can't create (unknown id, invalid variant), is detected.
  Never change a format's `id`: settings refer to it.
- A format instance is created per document (it may hold a variant) and must stay immutable:
  the UI thread and the indexing thread call it concurrently.
- `formats/registry.formatColumns` gives the columns of all variants of a format (a column
  layout is one per format id).

Adding a format, step by step: `.ai/workflows/add-format.md`.

## LogMessage

- `LogMessage!wchar` (`log_core/log_message`) is the format-neutral record:
  - a core: `timeNs` with its `TimeKind`, `level`, `payload`;
  - up to 8 fields by index, each a text or a number, with `hasField` telling whether the
    record has it.
- All texts live in one reused buffer whose size is derived from `maxRecordLength`, so
  decoding allocates nothing.
- Pass a `LogMessage` by `ref`, never `out` (see `.ai/rules/d.md`).

## DLT

- Parser: `formats/dlt/parser`, headers `formats/dlt/protocol`, `formats/dlt/header_v2`.
- DLT fields are read through UFCS accessors in `formats/dlt/fields` (`msg.ecuId`,
  `msg.appId`, ...). UFCS accessors don't work through a pointer.
- DLT records for unittests are built by `formats/dlt/testing_utils` (`BuildV1`, `BuildV2`,
  `buildDltMessage`), also for the tests of other packages.
- `.dlf` filter files of dlt-viewer: `formats/dlt/dlf`. FIBEX (non-verbose): `formats/dlt/fibex`,
  not decoded yet (`docs/fibex.md`).
- Real logs for trying things are kept locally in `test_data/`, not in the repository (`*.dlt`
  is ignored): a fresh clone has none. Tests build their records instead.

## Text Formats

- `TextFormat` (`log_core/text/text_format`) is the line-based base: multiline records, the
  record length limit.
- Parsing helpers (numbers, times, dates) live in `log_core/text/text_parsing`.
- `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12, even in release
  builds: check the month first.
