# Adding a Log Format

Background: `.ai/knowledge/formats.md`.

## Text Format

1. Tests first: sample lines in a unittest of the new module (decode, columns, detection
   score, multiline records if any).
2. Derive from `TextFormat` (`log_core/text/text_format`) and implement `decodeText`,
   `columns` and `name`. A line it can't parse goes to the payload as it is
   (`decodeAsPlainText`). Implement `isRecordStart` too if continuation lines are glued to
   their record. Parsing helpers: `log_core/text/text_parsing`. `scanRecords`, `recordAt`
   and `decode` are final: UTF-16 logs are read past them (`inEncoding`), and a format that
   doesn't derive from `TextFormat` gets no UTF-16.
3. One module in `formats/` (`formats/logcat.d`), or a package when it has several
   (`formats/syslog/`).
4. Declare the format's `FormatInfo`: a stable `id` (never changed later: settings refer to
   it), `name`, a three-letter `shortName` for the badge of a recent file. Return it from the
   detector's `info` and from the format's `info` (the same for every variant and encoding).
5. Add a `FormatDetector` (a score on the first 64 KB; plain text is the low-score fallback)
   and register it in `detectors()` of `formats/registry`. Add a registry test that a sample
   is detected as the new format and not as another. For a UTF-16 log `detect` and `create`
   get that head converted to UTF-8, without its byte order mark: other bytes and another
   length than the file's.
6. A column that needs a look of its own (a width) gets it in `resources/table.css`
   (`col-<format id>-<column id>`), not in the format.
   A short title (`sId`, `DLC`) gets its full name in `hint` (`"Session ID"`); a title that says it
   all leaves it empty.
   A column of little use to most users is hidden until the user shows it: `shownByDefault: false`.
7. Variants: the detector reports the variant, `createFormat` must refuse a variant the format
   doesn't have; `formatColumns` gives the columns of all variants.
8. Update `docs/formats.md`.

## Binary Format

As above, deriving from `LogFormat` directly (`log_core/log_format`): split the bytes into
records (`scanRecords`, resumable, leaving an incomplete last record for a later call) and
decode one into a `LogMessage` without allocating. See `formats/dlt/` and `formats/can/`.

## Messages Cut into Parts

When the writers of a format cut a long message into records of their own, the format also
implements `PartedFormat` (`log_core/log_format`): `marksOf` (of `MarkedFormat`, which it
extends) rules out most records by a few of their bytes, setting `RecordMark.part` only on
those that may be parts (asked of every record as the offset index grows, one look for all
the marks: keep it cheap), `partOf`
tells what a record it let through is as a part (the sender, its number and count, the
counter that comes next; or what it is as a piece of a text cut at a limit, `PieceKind`,
asked of every record while a cut one is open), and `decodeParts` decodes the parts as one record: the parts it
got, which may be fewer than the message has (a message closed before its last part came). The
index joins them (`domain/index/part_joiner`); the format knows nothing of the waiting. See
`formats/dlt/parts`.

## Files Sent in the Log

When the writers of a format send files as records (the file transfer of DLT), the
format also implements `TransferringFormat`: `marksOf` sets `RecordMark.transfer` on the
records that may be messages of a transfer, `transferOf` tells what one is (a start with the
file, a packet with its bytes, the end, an error). The index catalogs them
(`domain/index/transfers`). See `formats/dlt/file_transfer`; a format that is both shares one
look at the header in its `marksOf` (`DltFormat`).

## Checks

- The format instance is immutable after creation (UI and indexing threads call it).
- `LogMessage` is passed by `ref`, never `out`.
- `node scripts/build.mjs test` passes; open a sample in the app.
