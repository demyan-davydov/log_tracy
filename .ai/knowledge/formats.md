# Formats and Records

## Formats and Detection

- The formats supported now and the ones planned: `docs/formats.md`. Keep it up to date when
  a format or a variant is added.
- `formats/registry.detectFormat` asks every `FormatDetector` for a score on the first 64 KB
  and picks the best (in UTF-8: see Text Formats for UTF-16).
- Plain text is the low-score fallback; data no detector accepts is refused.
- A `.dlt` extension alone only decides for binary data.
- A recent file remembers the format it was opened with (`FormatChoice`: `FormatInfo.id`, the
  variant, the text encoding and the file of descriptions; the descriptions are taken apart
  from `createFormat` and detection, by the document, and dropped for a format of none) and opens in it again through `createFormat`, without
  detection; a file with no saved format, one this build can't create (unknown id, invalid
  variant) or whose data is not in the saved encoding (a UTF-16 mark or look) is detected.
  Never change a format's `id`: settings refer to it.
- A format tells its own `FormatInfo` (`LogFormat.info`, `Document.formatInfo`): what keys
  the column layouts and the filter files of a document, also of one made from a `ByteSource`
  with no `FormatChoice`. `FormatChoice` is only how to open a file the same way again.
- A format instance is created per document (it may hold a variant) and must stay immutable:
  the UI thread, the indexing thread (`scanRecords`) and the threads of a filter or a search
  call it concurrently. A document may replace its format by another instance of the same
  records (`Document.loadDescriptions`); the instance itself never changes.
- What a change of the format choice asks of a document is told by the choices, not the
  format objects (`log_core/log_format.formatChangeOf`): the id, variant and encoding decide
  the records (`FormatChange.records`: the file read anew), the descriptions only the
  decoding (`FormatChange.decoding`: `Document.loadDescriptions`). No format knows another; a format that
  takes descriptions must keep its records, parts and transfers the same whatever they are.
- A format may decode by a file of descriptions (`FormatChoice.descriptions`, a FIBEX for DLT):
  `formats/registry.takesDescriptions` and `withDescriptions` are what the other packages ask,
  never a cast to the concrete format; `formats/dlt/format.takesFibex`/`withFibex` behind them.
  `withDescriptions` reads the file on the caller's thread and may be stopped (its `stop`,
  asked between the files of a folder and every few thousand XML entities: null then). A
  document reads them on a thread of its own (`Document.loadDescriptions`): opened with a
  choice of descriptions, it opens at once and takes them once read, or tells why they can't
  be (`Document.descriptions`), the choice kept.
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
- A message its writer cut into numbered parts (verbose, one string argument `k/n: `) is one
  record: `formats/dlt/parts` tells a part (`dltPartOf`) and decodes the parts as one
  (`parseDltParts`); `DltFormat` is a `PartedFormat` through them. So is a message its
  writer cut with no mark at its limit of 1024 or 1023 bytes of text: `parts.tellPiece` is
  that rule on the format's side (`dltPieceLimits`, a piece of a limit or up to 3 bytes
  under it, no line break at its end), `PartJoiner.piecesGoOn` on the joiner's (the next counter, the
  same level, `maxPieceGap`, the room left), `RecordPart.piece` carries it between them
  (`docs/stories/cut-pieces.md`). The joining itself is the
  index's (`.ai/knowledge/architecture.md`, Indexing and Threads).
- A file sent in the log (the file transfer of DLT: FLST, FLDA, FLFI, FLER, verbose
  log messages whose first and last arguments are the marker) is told by
  `formats/dlt/file_transfer` (`dltTransferOf`); `DltFormat` is a `TransferringFormat`
  through it. Its `marksOf` walks the header once (`parser.findVerboseStart`, inlined for
  version 1 and by ref: a record is not cleared first) and takes one of the looks by the number of arguments,
  `dltMayBePartAt` (one) or `dltMayBeTransferAt` (three or more): it is asked of every record,
  measure a change of it (`bench --bench index`). The catalog is the index's; the story: `docs/stories/file-transfer.md`.
- DLT records for unittests are built by `formats/dlt/testing_utils` (`BuildV1`, `BuildV2`,
  `buildDltMessage`, `VerboseArgs` for the arguments of a verbose record), also for the
  tests of other packages.
- `.dlf` filter files: `formats/dlt/dlf`. FIBEX (non-verbose): `formats/dlt/fibex`
  reads the descriptions (`loadFibex`, `Fibex.find`); a `DltFormat` created with a `Fibex`
  decodes non-verbose messages by it (`parser.decodeByFibex`); a `Fibex` is `immutable`
  once read (`docs/stories/fibex.md`).
- `test_data/` is ignored by git: real logs kept at hand and local samples of every format,
  FIBEX and filter files (its README says what each is): a fresh clone has none. Tests build
  their records instead; a whole log (big, broken on purpose) is written by the generator
  (below).

## The Log Generator

- `formats/generator/`: writes a log of a format (`dlt`, `dlt-v2`, `text`), size and content,
  the same bytes for a seed (its own SplitMix64 `Rng`, not Phobos'). `content` gives the content
  of a record whatever the format and the options (`GenOptions`, the kinds of `Corruption`),
  `dlt` and `text` write it, `generator.generateLog` drives them and breaks records,
  `command_line` is the tool's options. The tool: `scripts/utils/gen_log.d`, built and run by
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
- Text formats parse UTF-8 only. UTF-16 is read by `inEncoding` (`log_core/text/text_format`):
  a `LogFormat` over the text format that finds lines and records in UTF-16 (a line ends at
  the code unit U+000A, not at a `0x0A` byte) and gives `isRecordStart`/`decodeText` their
  text converted to UTF-8 on the stack. A UTF-16 record is cut at 2/3 of `maxRecordLength`
  bytes, so its UTF-8 fits the limit every format relies on.
- The encoding (`log_core/text_encoding`) is decided by `formats/registry`, not by the
  formats. The detectors see the data as it is and, for UTF-16, in UTF-8: with a UTF-16 byte
  order mark UTF-16 wins whenever a format reads it (else the data is read as it is: binary
  bytes may look like a mark); without one, UTF-16 is guessed (`guessUtf16`) and wins only
  over a weaker detection of the data as it is (none, or the `.dlt` extension hint). The detectors and `FormatDetector.create` then get
  the head converted to UTF-8 (`utf8Head`). `FormatChoice.encoding` keeps it, saved as
  `"encoding"` of a recent file.
- `std.datetime`'s `valid!"days"` halts the process on a month outside 1..12, even in release
  builds: check the month first.
