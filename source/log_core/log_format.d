//! What a log format is to the rest of the program: LogFormat (records of bytes, their
//! decoding) with the columns of the table it declares (ColumnInfo), FormatDetector with what
//! it tells of a format (FormatInfo, Detection), and the format a file was opened with
//! (FormatChoice).
module log_core.log_format;

import log_core.log_level : LogLevel;
import log_core.log_message : LogMessage, TimeKind;
import log_core.text_encoding : TextEncoding;
import utils.ui_text : UiText, UiTextException;

//! Why a log could not be given a format: no format knows its data (`unrecognized`), or the
//! format asked for does not read it (`unreadable`). What the user can do about it differs from
//! a failure of the system (no file, no right): choose a format by hand.
class FormatException : UiTextException
{
    enum Kind : ubyte
    {
        unrecognized, //< detection found no format
        unreadable, //< the format asked for can't be made of the data
    }

    Kind kind;

    this(Kind kind, UiText text, string file = __FILE__, size_t line = __LINE__) @safe
    {
        super(text, file, line);
        this.kind = kind;
    }
}

//! What a column of the log table shows and how
enum ColumnKind : ubyte
{
    Time, // core time: microseconds (since the epoch or boot, see timeKind)
    Level, // core level
    Payload, // core payload, always the last column
    Text, // text of a field
    Integer, // number of a field
    Hex, // number of a field, shown in hex
    Duration, // number of a field, in 1/unitsPerSecond of a second
    Enum, // number of a field, shown as labels[number]
}

//! A column of the log table, as declared by a format. How it looks (its
//! width) is up to the style of the table, by the id of the format and the
//! column (resources/table.css).
struct ColumnInfo
{
    string id; // stable: the layouts in the settings and the style refer to it
    string title;
    ColumnKind kind;
    int field = -1; // LogMessage field for the field kinds
    TimeKind timeKind; // Time: how the time is shown
    long unitsPerSecond; // Duration
    string[] labels; // Enum
    bool byLevel; // the cell is colored by the level of its record (an HTTP status)
    string hint; // the full name of a short title ("Session ID" of "sId"), not translated; "": the title says it all
    bool shownByDefault = true; // shown in a table until the user's layout of the format says otherwise

    //! @returns true if the column shows a field, not the core
    bool isField() const pure nothrow @nogc @safe
    {
        return kind >= ColumnKind.Text;
    }
}

//! Result of LogFormat.scanRecords()
struct ScanResult
{
    size_t count; // record offsets written
    size_t next; // offset to continue scanning from
}

//! A log format: splits bytes into records and decodes them.
//!
//! A format knows nothing about files: it gets the bytes of a ByteSource and
//! works with offsets in them. Its methods are called at once from the UI
//! thread, the indexing thread (scanRecords for the offset index) and the many
//! threads of a filter or a search (utils/parallel_scan), so an instance must
//! not change after creation.
interface LogFormat
{
    //! What the user and the settings know the format by (its id, name and badge): the
    //! info of its detector, the same for every variant and encoding
    FormatInfo info() const pure nothrow @nogc;

    //! Columns of the log table, in the order shown; Payload is the last one
    const(ColumnInfo)[] columns() const pure nothrow @nogc;

    //! @brief Finds records in data[from .. $] and writes their offsets.
    //! Stops when `offsets` is full, at the end of the data, or after skipping
    //! a long run of bytes that are not records, so the caller gets control
    //! back regularly (to check for cancellation). Call again from `next`.
    //! @param final_ - no byte is waited for now (ByteSource.complete): a record
    //! cut by the end is let out, taken as it is where the format can tell a
    //! record by its end alone (a text line), else dropped. More bytes may come
    //! later (a file written after a pause): they are scanned as records of
    //! their own. Otherwise scanning stops before it (next is its start) and
    //! it is found by a later call, once its rest has arrived.
    //! @returns the number of offsets written and where to continue;
    //! with final_ the data is done once next == data.length
    ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc;

    //! @returns the bytes of the record starting at `offset` (as found by
    //! scanRecords), or an empty slice if there is no record there
    const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc;

    //! @brief Decodes a record returned by recordAt()
    //! @returns false if the bytes are not a valid record
    bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc;
}

//! What a record is to a message its writer cut with no mark: at a limit of its text, the
//! next record of the writer going on with it (a piece). Told for the records of one text
enum PieceKind : ubyte
{
    unknown, // not told: whose it is is not known
    other, // a record of the writer not of one text: it goes on with no cut piece
    text, // a record of one text: it may go on with a cut piece of its writer
    cut, // a record of one text cut at its writer's limit: the next one of the writer goes on
}

//! What a record is as a part of a message its writer cut: into numbered parts ("1/2: ...",
//! "2/2: ..."), or into pieces at a limit of its text (PieceKind), as PartedFormat.partOf
//! tells it
struct RecordPart
{
    enum long noTime = long.min;

    ubyte[16] sender; // who wrote it: the parts of a message come from one writer
    uint number; // 1-based; 0: the record is not a numbered part
    uint count; // of the parts of the message
    uint counter; // the writer's message counter of the record (0 without one)
    uint nextCounter; // the counter the next part has: they follow one by one
    PieceKind piece; // what it is to a message cut at a limit
    long time = noTime; // a piece: when its writer wrote it, in ns of the writer's clock
    uint room; // a cut piece: the bytes its writer left under the limit not to cut a character
    uint firstCharLength; // a piece of text: the bytes of its first character
    LogLevel level; // a piece: the level of the record (the pieces of a message have one)

    //! @returns true if the record is a numbered part of a message
    bool isPart() const pure nothrow @nogc @safe
    {
        return number != 0;
    }
}

//! What a record may be besides a record of its own, by a look at a few of its bytes
//! (MarkedFormat.marksOf): bits
enum RecordMark : ubyte
{
    none = 0,
    part = 1, // a part of a message, numbered or a piece cut at a limit: PartedFormat.partOf tells
    transfer = 2, // a message of a file sent in the log: TransferringFormat.transferOf tells
}

//! A format some of whose records may be more than records of their own (PartedFormat,
//! TransferringFormat, which are MarkedFormats too): the index asks it of every record
//! once, as the offset index grows, and the full question only of the records marked.
//! Asked of a format by a cast; immutable like the LogFormat it is.
interface MarkedFormat
{
    //! @returns the RecordMark bits of what the record at `offset` of the data (as
    //! scanRecords found it) may be: an unset bit rules it out surely, a set one leaves
    //! it to the full question (but for a record going on with a piece cut at a limit,
    //! which has no mark: PartedFormat.partOf). Asked of every record: keep it cheap, one
    //! look for all
    ubyte marksOf(const(ubyte)[] data, size_t offset) const nothrow @nogc;
}

//! A LogFormat whose writers may cut a long message into numbered parts or into pieces at
//! a limit of its text, written as records of their own: the index joins them into one
//! record (domain/index/part_joiner). It marks the records that may be numbered parts or
//! cut pieces (MarkedFormat). Asked of a format by a cast; immutable like the LogFormat
//! it is.
interface PartedFormat : MarkedFormat
{
    //! @returns what the record at `offset` of the data (as scanRecords found it) is as
    //! a part: a numbered one, or what it is to a piece cut at a limit (RecordPart.piece,
    //! with its sender); RecordPart.init if whose it is is not known. Asked of the records
    //! marked RecordMark.part, and of every record while a cut piece waits for the next
    //! (PartJoiner.followsPieces): what goes on with it has no mark
    RecordPart partOf(const(ubyte)[] data, size_t offset) const nothrow @nogc;

    //! @brief Decodes the parts of one message (as recordAt gives them, in order, the
    //! first one first) into one record: the fields of the first, the texts of all
    //! @returns false if the first part is not a valid record
    bool decodeParts(ref LogMessage!wchar msg, const(ubyte[])[] parts) const nothrow @nogc;
}

//! What a record is to a file its writer sends in the log (TransferringFormat.transferOf)
enum TransferKind : ubyte
{
    none, // not a message of a transfer
    start, // the file: its name, size, date, packets
    data, // a packet of its bytes
    end, // the last packet was sent
    error, // the file can't be sent: with its serial, or none when it could not be read
}

//! A message of a file sent in the log. The texts and bytes are slices of the data the
//! record was read from.
//!
//! What the catalog of the index (domain/index/transfers) takes of the messages, whatever
//! the protocol: the messages of one transfer have one serial, a start opens a transfer
//! (another start of the serial leaves the one before as it is), a packet or an end goes to
//! the newest open transfer of its serial (a packet of none opens one: the log began during
//! the transfer), an error closes it as failed (one without a serial, or of none open, is a
//! failed transfer of its own), packets are numbered from 1 and the file is read from those
//! that came in turn. A protocol of other rules needs them in the catalog first.
struct TransferMessage
{
    TransferKind kind;
    bool hasSerial; // the transfer it belongs to is known: all but an error without a file
    uint serial; // of the file: the messages of one transfer have the same

    // start, an error with a file (name alone for an error without one)
    const(char)[] name;
    ulong size; // bytes
    const(char)[] date; // as the writer wrote it
    uint packets;
    uint bufferSize; // the bytes of a packet, the last one may have fewer

    // data
    uint packet; // 1-based
    const(ubyte)[] bytes;

    // error
    long error; // the code of the writer
    long osError; // errno of its system, negative
}

//! A LogFormat whose writers may send files as records of the log (the file transfer of
//! DLT): the index keeps a catalog of them (domain/index/transfers). It marks the
//! records that may be messages of a transfer (MarkedFormat). Asked of a format by a
//! cast; immutable like the LogFormat it is.
interface TransferringFormat : MarkedFormat
{
    //! @returns what the record at `offset` of the data (as scanRecords found it) is to a
    //! transfer: kind none if it is not a message of one. Asked only of the records
    //! marked RecordMark.transfer
    TransferMessage transferOf(const(ubyte)[] data, size_t offset) const nothrow @nogc;
}

//! How well some bytes fit a format
struct Detection
{
    float score = 0; // 0 - not this format, 1 - certainly this format
    int variant; // format-specific, passed to FormatDetector.create()
}

//! What the user and the settings know a format by
struct FormatInfo
{
    string id; // stable, saved in the settings: never change it
    string name; // shown to the user, e.g. "Android logcat"
    string shortName; // three capital letters, e.g. "ADB": the badge of a file
}

//! The format a file was opened with, to open it the same way again:
//! the detector (FormatInfo.id), the variant it created and the encoding of
//! the text it read
struct FormatChoice
{
    string id; // empty: none, the format is to be detected
    int variant;
    TextEncoding encoding; // of a text format; utf8 for a binary one
    // The file (or folder) of the descriptions the records are decoded by, empty for none:
    // a FIBEX for DLT (formats/registry: withDescriptions)
    string descriptions;

    bool isSet() const pure nothrow @nogc @safe
    {
        return id.length != 0;
    }
}

//! What a change of the format choice of a document asks of it (formatChangeOf)
enum FormatChange : ubyte
{
    none, //< the same choice
    decoding, //< the same records, decoded another way: the views are built again
    records, //< other records: the file is read anew, its records numbered anew
}

//! @brief What changing the format choice of a document `from` to `to` asks of it. The records
//! a format splits the data into, joins the parts of and catalogs the files of are told by its
//! id, variant and encoding; its descriptions change the decoding only (a format that takes
//! them must keep its records so: formats/registry, withDescriptions). The descriptions are
//! compared by their path: `none` doesn't tell their content is the same (a FIBEX written
//! again at its path), so loading descriptions again replaces the format all the same
FormatChange formatChangeOf(const FormatChoice from, const FormatChoice to) pure nothrow @nogc @safe
{
    if (!from.isSet || from.id != to.id || from.variant != to.variant || from.encoding != to.encoding)
        return FormatChange.records;
    return from.descriptions == to.descriptions ? FormatChange.none : FormatChange.decoding;
}

//! Recognises one log format by the start of the data
interface FormatDetector
{
    //! The format this detector recognises
    FormatInfo info() const pure nothrow @nogc;

    //! @param path - name of the source, a hint only (its extension)
    //! @param head - the first bytes of the data
    Detection detect(string path, const(ubyte)[] head) const;

    //! Creates the format for a detected variant
    LogFormat create(int variant, const(ubyte)[] head) const;

    //! Every variant create() takes: the columns of a format are those of
    //! all its variants (the layout of the columns is kept per format)
    const(int)[] variants() const pure nothrow;
}

@("formatChangeOf: the descriptions change the decoding only, the id, variant or encoding the records")
unittest
{
    const dlt = FormatChoice("dlt");
    FormatChoice described = dlt;
    described.descriptions = "/fibex/ecu.xml";
    FormatChoice other = described;
    other.descriptions = "/fibex/other.xml";

    assert(formatChangeOf(dlt, dlt) == FormatChange.none);
    assert(formatChangeOf(described, described) == FormatChange.none);
    assert(formatChangeOf(dlt, described) == FormatChange.decoding, "a FIBEX loaded");
    assert(formatChangeOf(described, dlt) == FormatChange.decoding, "a FIBEX dropped");
    assert(formatChangeOf(described, other) == FormatChange.decoding, "another FIBEX");

    assert(formatChangeOf(dlt, FormatChoice("text")) == FormatChange.records, "another format");
    assert(formatChangeOf(FormatChoice("logcat", 0), FormatChoice("logcat", 1)) == FormatChange.records,
        "another variant");
    assert(formatChangeOf(FormatChoice("text"), FormatChoice("text", 0, TextEncoding.utf16le))
        == FormatChange.records, "another encoding: other bytes per line");
    assert(formatChangeOf(FormatChoice.init, dlt) == FormatChange.records, "a format chosen for none");
}
