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
  the UI thread, the indexing thread (`scanRecords`) and the threads of a filter or a search
  call it concurrently.
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
- The length of a record is decided in one place, `DltFormat.layoutOf`, for the scan and for
  `recordAt` alike (the index keeps offsets only): with storage headers a length too long is
  cut at the first storage header inside the record when none follows it (`cutAtNextHeader`,
  O(1) for a sound record).
- DLT records for unittests are built by `formats/dlt/testing_utils` (`BuildV1`, `BuildV2`,
  `buildDltMessage`), also for the tests of other packages.
- `.dlf` filter files of dlt-viewer: `formats/dlt/dlf`. FIBEX (non-verbose): `formats/dlt/fibex`,
  not decoded yet (`docs/fibex.md`).
- Real logs for trying things are kept locally in `test_data/`, not in the repository (`*.dlt`
  is ignored): a fresh clone has none. Tests build their records instead; a whole log (big,
  broken on purpose) is written by the generator (below).

## The Log Generator

- `formats/generator/`: writes a log of a format (`dlt`, `dlt-v2`, `text`), size and content,
  the same bytes for a seed (its own SplitMix64 `Rng`, not Phobos'). `content` gives the content
  of a record whatever the format and the options (`GenOptions`, the kinds of `Corruption`),
  `dlt` and `text` write it, `generator.generateLog` drives them and breaks records,
  `command_line` is the tool's options. The tool: `scripts/gen_log.d`, built and run by
  `node scripts/build.mjs gen-log`.
- Its modules and `formats/dlt/testing_utils` are under `version (unittest)` or
  `-d-version=LogGenerator`: not in the program. DLT records are built by the same `BuildV1`/`BuildV2`
  as the tests.
- A new format of the generator: a writer module, its `GenFormat` and name, its corruptions in
  `corruptionsOf`, and the cases of the tests of `generator` (detected as its format, every
  record read).

## Text Formats

- `TextFormat` (`log_core/text/text_format`) is the line-based base: multiline records, the
  record length limit.
- Parsing helpers (numbers, times, dates) live in `log_core/text/text_parsing`.
- `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12, even in release
  builds: check the month first.
