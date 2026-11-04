module log_core.log_format;

import log_core.log_message : LogMessage, TimeKind;

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

//! A column of the log table, as declared by a format
struct ColumnInfo
{
    string id; // stable, e.g. to remember the width of the column
    string title;
    ColumnKind kind;
    int field = -1; // LogMessage field for the field kinds
    ushort width; // initial width in px; 0: the rest of the table
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
//! works with offsets in them. Its methods are called from the indexing thread
//! and the UI thread at once, so an instance must not change after creation.
interface LogFormat
{
    //! Name shown to the user, e.g. "DLT"
    string name() const pure nothrow @nogc;

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
//! the detector (FormatInfo.id) and the variant it created
struct FormatChoice
{
    string id; // empty: none, the format is to be detected
    int variant;

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
}
