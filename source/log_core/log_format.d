//! What a log format is to the rest of the program: LogFormat (records of bytes, their
//! decoding) with the columns of the table it declares (ColumnInfo), FormatDetector with what
//! it tells of a format (FormatInfo, Detection), and the format a file was opened with
//! (FormatChoice).
module log_core.log_format;

import log_core.log_message : LogMessage, TimeKind;
import log_core.text_encoding : TextEncoding;

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
    //! @param final_ - no more bytes will come: an incomplete record at the end
    //! is dropped. Otherwise scanning stops before it (next is its start) and
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

//! What a record is as a part of a message its writer cut into numbered parts
//! ("1/2: ...", "2/2: ..."), as PartedFormat.partOf tells it
struct RecordPart
{
    ubyte[16] sender; // who wrote it: the parts of a message come from one writer
    uint number; // 1-based; 0: the record is not a part
    uint count; // of the parts of the message
    uint counter; // the writer's message counter of the record (0 without one)
    uint nextCounter; // the counter the next part has: they follow one by one

    //! @returns true if the record is a part of a message
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
    part = 1, // a part of a message: PartedFormat.partOf tells
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
    //! it to the full question. Asked of every record: keep it cheap, one look for all
    ubyte marksOf(const(ubyte)[] data, size_t offset) const nothrow @nogc;
}

//! A LogFormat whose writers may cut a long message into numbered parts, written as
//! records of their own: the index joins them into one record (domain/index/part_joiner).
//! It marks the records that may be parts (MarkedFormat). Asked of a format by a cast;
//! immutable like the LogFormat it is.
interface PartedFormat : MarkedFormat
{
    //! @returns what the record at `offset` of the data (as scanRecords found it) is as
    //! a part; not a part: RecordPart.init. Asked only of the records marked
    //! RecordMark.part
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

    bool isSet() const pure nothrow @nogc @safe
    {
        return id.length != 0;
    }
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
