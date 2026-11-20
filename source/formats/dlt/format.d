//! DltFormat: DLT logs, files and streams of protocol versions 1 and 2, as a LogFormat:
//! their columns, the split of the bytes into records and their decoding.
module formats.dlt.format;

import formats.dlt.protocol;
import formats.dlt.fibex : Fibex;
import formats.dlt.parser : parseDltItem;
import formats.dlt.file_transfer : dltMayBeTransferAt, dltTransferOf;
import formats.dlt.parser : VerboseStart, findVerboseStart, storageSizeOf;
import formats.dlt.parts : dltMayBePartAt, dltPartOf, parseDltParts;
import formats.dlt.header_v2 : HeaderV2, HeaderV2Status, baseHeaderV2Size, messageLengthV2,
    protocolVersion, readHeaderV2;

import log_core.log_format;
import log_core.log_message : LogMessage, TimeKind;
import formats.dlt.fields : DltField;

import std.algorithm.comparison : max, min;

//! How the user and the settings know DltFormat
enum FormatInfo dltFormatInfo = FormatInfo("dlt", "DLT", "DLT");

//! @returns true if the records of `format` can be decoded by a FIBEX (withFibex)
bool takesFibex(const(LogFormat) format) pure nothrow @nogc
{
    return cast(const(DltFormat)) format !is null;
}

//! @brief `format` decoding by `fibex` (none for null): the same records, the bytes split the
//! same way, non-verbose messages decoded another way
//! @returns null if `format` takes no FIBEX (takesFibex)
LogFormat withFibex(const(LogFormat) format, immutable Fibex fibex) pure nothrow
{
    const dlt = cast(const(DltFormat)) format;
    return dlt is null ? null : new DltFormat(dlt.hasStorageHeader, fibex);
}

//! DLT messages, with a storage header (DLT files) or without one (streams).
//! Record layout: [ Storage Header ] Standard Header [ ... ] where the
//! standard header holds the length of the message without the storage header.
//! Both versions of the protocol and of the storage header, mixed in any way.
//! A message its writer cut into numbered parts is one record (formats/dlt/parts); the
//! messages of a file sent in the log are told (formats/dlt/file_transfer). Non-verbose
//! messages are decoded by the FIBEX of the format, if it has one (formats/dlt/fibex).
final class DltFormat : LogFormat, PartedFormat, TransferringFormat
{
    private immutable bool _hasStorageHeader;
    private immutable Fibex _fibex; // read concurrently: never changed

    //! The most bytes scanRecords() skips looking for a storage header before
    //! returning control to the caller
    enum size_t maxHeaderScan = 1024 * 1024;

    this(bool hasStorageHeader = true, immutable Fibex fibex = null) pure nothrow @nogc @safe
    {
        _hasStorageHeader = hasStorageHeader;
        _fibex = fibex;
    }

    //! The FIBEX non-verbose messages are decoded by, null if none
    immutable(Fibex) fibex() const pure nothrow @nogc
    {
        return _fibex;
    }

    bool hasStorageHeader() const pure nothrow @nogc @property
    {
        return _hasStorageHeader;
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return dltFormatInfo;
    }

    private static immutable ColumnInfo[] _columns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, TimeKind.Absolute),
        ColumnInfo("timestamp", "Timestamp", ColumnKind.Duration, DltField.Timestamp,
            TimeKind.None, 10_000),
        ColumnInfo("counter", "Cnt", ColumnKind.Integer, DltField.Counter, hint: "Message counter"),
        ColumnInfo("ecu", "Ecu", ColumnKind.Text, DltField.EcuId, hint: "ECU ID"),
        ColumnInfo("app", "App", ColumnKind.Text, DltField.AppId, hint: "Application ID"),
        ColumnInfo("ctx", "Ctx", ColumnKind.Text, DltField.CtxId, hint: "Context ID"),
        ColumnInfo("session", "sId", ColumnKind.Integer, DltField.SessionId, hint: "Session ID"),
        ColumnInfo("type", "Type", ColumnKind.Enum, DltField.Type,
            TimeKind.None, 0, ["LOG", "APP", "NW", "CTRL"]),
        ColumnInfo("level", "Level", ColumnKind.Level, -1),
        ColumnInfo("msgid", "Msg", ColumnKind.Integer, DltField.MessageId, hint: "Message ID"),
        ColumnInfo("payload", "Payload", ColumnKind.Payload),
    ];

    override const(ColumnInfo)[] columns() const pure nothrow @nogc
    {
        return _columns;
    }

    override ScanResult scanRecords(const(ubyte)[] data, size_t from, size_t[] offsets, bool final_) const nothrow @nogc
    {
        size_t pos = from;
        size_t count = 0;

        while (count < offsets.length && pos < data.length)
        {
            size_t start = pos;
            if (_hasStorageHeader)
            {
                const window = data[pos .. min(data.length, pos + maxHeaderScan)];
                const found = findNextStorageHeader(window);
                if (found.length == 0)
                {
                    // Keep the tail that may be the start of a header
                    const keep = min(window.length, StorageHeader.sizeof - 1);
                    if (pos + window.length < data.length)
                    {
                        pos += window.length - keep; // continue after the window
                        break; // a long run without headers: give control back
                    }
                    pos = final_ ? data.length : data.length - keep;
                    break;
                }
                start = found.ptr - data.ptr;
            }

            const layout = layoutOf(data[start .. $]);
            const length = layout.length;
            if (length == 0) // the record runs past the end of the data
            {
                if (!final_)
                {
                    pos = start; // it may still be growing
                    break;
                }
                if (!_hasStorageHeader)
                {
                    pos = data.length;
                    break;
                }
                // A truncated last record or a corrupt length: look for the
                // next header inside it
                pos = start + DLT_PATTERN.length;
                continue;
            }

            if (!layout.coversHeaders)
            {
                // A corrupt length: look for the next header inside this record,
                // a stream without storage headers can only trust the length
                pos = _hasStorageHeader ? start + DLT_PATTERN.length : start + length;
                continue;
            }

            offsets[count++] = start;
            pos = start + length;
        }

        return ScanResult(count, pos);
    }

    override const(ubyte)[] recordAt(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        // The header is checked in place, not searched for: a missing header
        // means the data is gone (a lost file reads as zeros), and searching
        // would scan the whole rest of the file.
        if (offset >= data.length)
            return null;
        const buffer = data[offset .. $];
        if (_hasStorageHeader && !startsWithStorageHeader(buffer))
            return null;

        const layout = layoutOf(buffer);
        if (layout.length == 0 || !layout.coversHeaders)
            return null;
        return buffer[0 .. layout.length];
    }

    override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
    {
        return parseDltItem!wchar(msg, record, _hasStorageHeader, _fibex);
    }

    override ubyte marksOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        // One walk over the header for both looks: asked of every record
        const record = data[offset .. $];
        const storage = _hasStorageHeader ? storageSizeOf(record) : 0;
        if (storage >= record.length)
            return RecordMark.none;
        const message = record[storage .. $];
        VerboseStart start;
        if (!findVerboseStart(message, start))
            return RecordMark.none;
        // A part has one argument, a message of a transfer three or more: one look or the other
        if (start.arguments == 1)
            return dltMayBePartAt(message, start) ? RecordMark.part : RecordMark.none;
        return dltMayBeTransferAt(message, start) ? RecordMark.transfer : RecordMark.none;
    }

    override RecordPart partOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        return dltPartOf(data[offset .. $], _hasStorageHeader);
    }

    override bool decodeParts(ref LogMessage!wchar msg, const(ubyte[])[] parts) const nothrow @nogc
    {
        return parseDltParts!wchar(msg, parts, _hasStorageHeader);
    }

    override TransferMessage transferOf(const(ubyte)[] data, size_t offset) const nothrow @nogc
    {
        // The record as recordAt cuts it: a length too long is not trusted
        return dltTransferOf(recordAt(data, offset), _hasStorageHeader);
    }

    //! @returns the layout of the record at the start of `buffer`. Versions 0
    //! (old loggers) and 1 share their headers; the length of a version 3..7
    //! message is taken where version 1 has it, its headers are left to the
    //! decoder, which says it can't show them.
    private RecordLayout layoutOf(const(ubyte)[] buffer) const nothrow @nogc
    {
        RecordLayout layout;

        size_t storage = 0;
        if (_hasStorageHeader)
        {
            storage = readStorageHeader(buffer).size;
            if (storage == 0)
                return layout; // cut
        }

        // A corrupt length shorter than the base header still moves on
        const message = buffer[storage .. $];
        const version_ = protocolVersion(message);
        size_t length;
        size_t baseHeader;
        if (version_ == 2)
        {
            baseHeader = baseHeaderV2Size;
            if (message.length < baseHeader)
                return layout;
            length = max(messageLengthV2(message), baseHeader);
        }
        else
        {
            baseHeader = StandardHeader.sizeof;
            if (message.length < baseHeader)
                return layout;
            length = max((cast(const(StandardHeader)*) message.ptr).nativeLength, baseHeader);
        }
        if (storage + length > buffer.length)
            return layout;
        if (_hasStorageHeader)
            length = cutAtNextHeader(buffer, storage + baseHeader, storage + length) - storage;

        const record = message[0 .. length];
        if (version_ == 2)
        {
            HeaderV2 header;
            // Reserved values: shown as an invalid header, the length is right
            layout.coversHeaders = readHeaderV2(record, header) != HeaderV2Status.cut;
        }
        else if (version_ <= 1)
        {
            auto standardHeader = cast(const(StandardHeader)*) record.ptr;
            // The length may have been cut short of the one in the header
            layout.coversHeaders = min(standardHeader.nativeLength, length)
                >= standardHeader.fullHeaderAndExtendedHeaderSize();
        }
        else
            layout.coversHeaders = true;

        layout.length = storage + length;
        return layout;
    }
}

//! Where the record at the start of a buffer ends, and if it is sound
private struct RecordLayout
{
    size_t length; // with the storage header; 0: the buffer ends before the record does
    bool coversHeaders; // the length covers the headers the record announces
}

//! Recognises DLT files by their storage header
final class DltDetector : FormatDetector
{
    override const(int)[] variants() const pure nothrow
    {
        return [0]; // one, whatever the variant
    }

    override FormatInfo info() const pure nothrow @nogc
    {
        return dltFormatInfo;
    }

    override Detection detect(string path, const(ubyte)[] head) const
    {
        import std.path : extension;
        import std.uni : sicmp;

        if (startsWithStorageHeader(head))
            return Detection(1.0f);
        if (findNextStorageHeader(head).length != 0)
            return Detection(0.8f); // garbage before the first message
        // Only decides for binary data: below the plain text fallback, so
        // text in a .dlt file opens as text
        if (sicmp(extension(path), ".dlt") == 0)
            return Detection(0.04f);
        return Detection(0);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        return new DltFormat(true);
    }
}

//! @returns true if `buffer` starts with a storage header pattern and holds
//! at least a storage header of version 1
private bool startsWithStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
{
    return buffer.length >= StorageHeader.sizeof && startsWithStoragePattern(buffer);
}

//! @returns slice of original buffer starting from a storage header pattern
//! ("DLT\x01" or "DLT\x02") or empty slice reffered to bufferEnd
//! @note The result slice will have at least StorageHeader.sizeof bytes,
//! otherwise the empty slice is returned
private const(ubyte)[] findNextStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
{
    if (buffer.length < StorageHeader.sizeof)
        return buffer[$ .. $];

    const last = buffer.length - StorageHeader.sizeof;
    for (size_t i = 0; i <= last; ++i)
    {
        if (buffer[i] == DLT_PATTERN[0] && isPlausibleStorageHeader(buffer[i .. $]))
            return buffer[i .. $];
    }

    return buffer[$ .. $];
}

//! @returns where the record at the start of `buffer`, `end` bytes long by its
//! length, really ends. A corrupt length too long would cover the records
//! after it: when no storage header follows the record (nor the end of the
//! data, nor the start of a header still being written), the first storage
//! header inside it ends it. The check is O(1) for a sound record, which
//! every row pays (`recordAt`); only a broken record pays for the search.
//! A length too short isn't fixed here: the scan skips to the next header.
//! The search starts at `from`, after the record's own base header: the
//! bytes of its own headers (ECU ID, counter) don't cut it.
private size_t cutAtNextHeader(const(ubyte)[] buffer, size_t from, size_t end) pure @nogc nothrow
{
    const after = buffer[end .. $];
    if (after.length >= DLT_PATTERN.length ? startsWithStoragePattern(after)
        : after == DLT_PATTERN[0 .. after.length])
        return end;
    // A header starting inside the message, whole in the buffer
    const area = buffer[from .. min(buffer.length, end + StorageHeader.sizeof - 1)];
    const found = findNextStorageHeader(area);
    return found.length == 0 ? end : found.ptr - buffer.ptr;
}

//! @returns true if `buffer` starts with a storage header pattern followed by
//! what may be a message: false when the pattern is only bytes of a payload
//! (a message of an unknown version follows). A buffer that ends before the
//! message may still hold one.
private bool isPlausibleStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
{
    if (!startsWithStoragePattern(buffer))
        return false;
    const size = readStorageHeader(buffer).size;
    if (size == 0 || size >= buffer.length)
        return true;
    return protocolVersion(buffer[size .. $]) <= 2;
}

// ─── Test Helpers ──────────────────────────────────────────────────────────

version (unittest)
{
    import formats.dlt.testing_utils : BuildV1, buildDltMessage;

    /// All records of `data` scanned in one go, as the index does for a file
    private size_t[] scanAll(const(DltFormat) format, const(ubyte)[] data)
    {
        size_t[] result;
        size_t[4] offsets;
        size_t pos = 0;
        while (pos < data.length)
        {
            const r = format.scanRecords(data, pos, offsets[], true);
            result ~= offsets[0 .. r.count];
            assert(r.next > pos || r.count > 0, "scanning must make progress");
            pos = r.next;
        }
        return result;
    }
}

// ─── findNextStorageHeader tests ───────────────────────────────────────────

@("findNextStorageHeader: finds header at start of buffer")
unittest
{
    ubyte[StorageHeader.sizeof] buf;
    buf[0 .. 4] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == buf.ptr);
    assert(result.length == StorageHeader.sizeof);
}

@("findNextStorageHeader: finds header after garbage bytes")
unittest
{
    ubyte[] buf;
    buf.length = 10 + StorageHeader.sizeof;
    buf[] = 'X';
    buf[10 .. 14] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == &buf[10]);
}

@("findNextStorageHeader: returns empty slice when no header found")
unittest
{
    ubyte[StorageHeader.sizeof] buf = 'X';
    auto result = findNextStorageHeader(buf[]);
    assert(result.length == 0);
}

@("findNextStorageHeader: partial DLT pattern is not matched")
unittest
{
    ubyte[] buf;
    buf.length = StorageHeader.sizeof;
    buf[] = '\0';
    buf[0] = 'D';
    buf[1] = 'L';
    buf[2] = 'T';
    buf[3] = '\03'; // no storage header has version 3
    auto result = findNextStorageHeader(buf[]);
    assert(result.length == 0);
}

@("findNextStorageHeader: multiple headers — returns first")
unittest
{
    ubyte[] buf;
    buf.length = StorageHeader.sizeof * 2;
    buf[] = '\0';
    buf[0 .. 4] = DLT_PATTERN;
    buf[StorageHeader.sizeof .. StorageHeader.sizeof + 4] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == buf.ptr);
}

@("findNextStorageHeader: buffer too small for StorageHeader")
unittest
{
    ubyte[3] buf = cast(ubyte[]) "DLT";
    auto result = findNextStorageHeader(buf[]);
    assert(result.length == 0);
}

@("findNextStorageHeader: header at the very end of buffer")
unittest
{
    ubyte[] buf;
    buf.length = 20 + StorageHeader.sizeof;
    buf[] = 'X';
    buf[20 .. 24] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == &buf[20]);
}

// ─── DltFormat.scanRecords tests ──────────────────────────────────────────

@("DltFormat.scanRecords: finds every message at its offset")
unittest
{
    auto msg1 = buildDltMessage("ECU1", 100, 0, 0, 1, [0xAA, 0xBB]);
    auto msg2 = buildDltMessage("ECU2", 200, 0, 0, 2, [0xCC, 0xDD, 0xEE]);
    auto msg3 = buildDltMessage("ECU3", 300, 0, 0, 3);
    auto data = msg1 ~ msg2 ~ msg3;

    auto format = new DltFormat();
    assert(scanAll(format, data) == [0, msg1.length, msg1.length + msg2.length]);
}

@("DltFormat.scanRecords: stops when the offsets are full and continues from next")
unittest
{
    ubyte[] data;
    foreach (i; 0 .. 5)
        data ~= buildDltMessage("ECU1", i, 0, 0, cast(ubyte) i, [0x42]);
    const size = data.length / 5;

    auto format = new DltFormat();
    size_t[2] offsets;
    auto r = format.scanRecords(data, 0, offsets[], true);
    assert(r.count == 2 && offsets == [0, size]);
    assert(r.next == 2 * size);

    r = format.scanRecords(data, r.next, offsets[], true);
    assert(r.count == 2 && offsets == [2 * size, 3 * size]);
}

@("DltFormat.scanRecords: empty data has no records")
unittest
{
    size_t[4] offsets;
    const r = new DltFormat().scanRecords(null, 0, offsets[], true);
    assert(r.count == 0 && r.next == 0);
}

@("DltFormat.scanRecords: skips garbage before a message")
unittest
{
    ubyte[] garbage = [0xFF, 0xFE, 0xFD, 0xFC, 0xFB];
    auto msg = buildDltMessage("ECU1", 300, 0, 0, 1, [0x42]);
    assert(scanAll(new DltFormat(), garbage ~ msg) == [garbage.length]);
}

@("DltFormat.scanRecords: data without headers has no records")
unittest
{
    auto garbage = new ubyte[](100);
    garbage[] = 0xEE;
    assert(scanAll(new DltFormat(), garbage).length == 0);
}

@("DltFormat.scanRecords: scans for a header at most maxHeaderScan bytes per call")
unittest
{
    enum scan = DltFormat.maxHeaderScan;
    auto msg = buildDltMessage("ECU1", 1, 0, 0, 1, [0x42]);
    auto garbage = new ubyte[](3 * scan + 123);
    garbage[] = 0xFF;
    auto data = garbage ~ msg;

    auto format = new DltFormat();
    size_t[4] offsets;
    size_t pos = 0;
    size_t emptyCalls = 0;
    ScanResult r;
    while (true)
    {
        r = format.scanRecords(data, pos, offsets[], true);
        if (r.count)
            break;
        assert(r.next - pos <= scan, "one call scans at most maxHeaderScan bytes");
        assert(r.next > pos, "a call without records still makes progress");
        pos = r.next;
        ++emptyCalls;
    }

    assert(emptyCalls == 3, "the garbage is skipped over several calls");
    assert(r.count == 1 && offsets[0] == garbage.length, "message start is known");
}

@("DltFormat.scanRecords: finds a header crossing the end of the scan window")
unittest
{
    enum scan = DltFormat.maxHeaderScan;
    auto msg = buildDltMessage("ECU1", 1, 0, 0, 1, [0x42]);
    auto garbage = new ubyte[](scan - 5); // the header starts 5 bytes before the window end
    garbage[] = 0xFF;
    assert(scanAll(new DltFormat(), garbage ~ msg) == [garbage.length]);
}

@("DltFormat.scanRecords: a truncated last message is dropped at the end of data")
unittest
{
    auto msg1 = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3, 4]);
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [1, 2, 3, 4]);
    auto data = msg1 ~ msg2[0 .. $ - 2];

    auto format = new DltFormat();
    assert(scanAll(format, data) == [0], "no crash, the complete message is kept");
}

@("DltFormat.scanRecords: without final_ an incomplete message waits for its rest")
unittest
{
    auto msg1 = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3, 4]);
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [1, 2, 3, 4]);
    auto data = msg1 ~ msg2;
    auto format = new DltFormat();
    size_t[4] offsets;

    // Cut inside the payload, inside the standard header, inside the storage header
    foreach (cut; [data.length - 2, msg1.length + StorageHeader.sizeof + 1, msg1.length + 3])
    {
        auto r = format.scanRecords(data[0 .. cut], 0, offsets[], false);
        assert(r.count == 1 && offsets[0] == 0);
        assert(r.next <= msg1.length, "the incomplete message is not consumed");

        r = format.scanRecords(data, r.next, offsets[], false);
        assert(r.count == 1 && offsets[0] == msg1.length, "found once complete");
        assert(r.next == data.length);
    }
}

@("DltFormat.scanRecords: messages without storage header")
unittest
{
    auto msg1 = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3]);
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [4, 5]);
    auto data = msg1[StorageHeader.sizeof .. $] ~ msg2[StorageHeader.sizeof .. $];
    const len1 = msg1.length - StorageHeader.sizeof;

    auto format = new DltFormat(false);
    assert(scanAll(format, data) == [0, len1]);
    assert(scanAll(format, data ~ cast(ubyte[])[0x01]) == [0, len1],
        "a tail shorter than a header ends the scan");
}

// ─── DltFormat.recordAt / decode tests ─────────────────────────────────────

@("DltFormat.recordAt: checks the header at the offset instead of searching")
unittest
{
    auto msg = buildDltMessage("ECU1", 1, 0, 0, 1, [0x42]);
    ubyte[] garbage = [0xFF, 0xFE, 0xFD];
    auto data = garbage ~ msg;

    auto format = new DltFormat();
    assert(format.recordAt(data, garbage.length) == msg, "a message at its offset");
    assert(format.recordAt(data, 0).length == 0, "garbage at the offset: no message");
    assert(format.recordAt(data, data.length).length == 0, "offset at the end");
    assert(format.recordAt(data[0 .. $ - 1], garbage.length).length == 0, "truncated");
}

@("DltFormat.decode: decodes a record with its extended header")
unittest
{
    import formats.dlt.fields;

    BuildV1 r; // verbose, with the extended header of APP1/CTX1
    r.storageEcu = "ECU1";
    r.storageSeconds = 400;
    r.protocolVersion = 0;
    r.msbf = false;
    r.typeInfo = 0;
    r.counter = 5;
    auto data = r.bytes();

    auto format = new DltFormat();
    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(msg.ecuId == "ECU1"w);
    assert(msg.appId == "APP1"w);
    assert(msg.ctxId == "CTX1"w);
    assert(msg.timestampSeconds == 400);
}

@("DltFormat.decode: reuses the buffer of the message")
unittest
{
    auto data = buildDltMessage("ECU1", 1, 0, 0, 1, [0x42]);
    auto format = new DltFormat();
    LogMessage!wchar msg;

    assert(format.decode(msg, format.recordAt(data, 0)));
    const firstText = msg.text(0).ptr;
    foreach (_; 0 .. 3)
    {
        assert(format.decode(msg, format.recordAt(data, 0)));
        assert(msg.text(0).ptr is firstText, "no new buffer per decode");
    }

    assert(!format.decode(msg, null));
    assert(msg.text(0) is null, "a failed decode leaves no stale record");
}

@("DltFormat columns: a filter rule finds an ID by its trimmed value")
unittest
{
    import formats.dlt.fields : beginDltRecord;
    import log_core.rule_filter : Check, Condition, FilterRule, FilterSet, RuleFilter;

    FilterSet set;
    set.rules = [FilterRule("", FilterRule.init.kind, true, "",
            [Condition("ecu", Check.Equals, "CU7"), Condition("app", Check.Equals, "APP1")])];
    auto filter = RuleFilter.compile(new DltFormat().columns, [set]);
    LogMessage!wchar msg;
    msg.beginDltRecord("CU7 ", "APP1", "CTX1");
    assert(filter.matches(msg), "the padding is not part of the ID");
    msg.beginDltRecord("ECU1", "APP1", "CTX1");
    assert(!filter.matches(msg));
}

// ─── DltDetector tests ─────────────────────────────────────────────────────

@("DltDetector: a storage header at the start is certain, the extension is a hint")
unittest
{
    auto detector = new DltDetector();
    auto msg = buildDltMessage();
    ubyte[] text = cast(ubyte[]) "11-03 14:22:01.123  1234  1250 I Tag: text\n".dup;

    assert(detector.detect("x.log", msg).score == 1.0f);
    assert(detector.detect("x.log", cast(ubyte[])[0x01, 0x02] ~ msg).score == 0.8f);
    assert(detector.detect("x.DLT", text).score == 0.04f);
    assert(detector.detect("x.log", text).score == 0);
}

@("DltFormat.scanRecords: a record shorter than its own headers is skipped")
unittest
{
    // The length (4) doesn't cover the extended header (10) or the ECU ID (4) the flags announce
    auto shortExtended = buildDltMessage("ECU1", 1, 0, StandardHeader.Type.UseExtendedHeader, 1);
    auto shortEcuId = buildDltMessage("ECU1", 2, 0, StandardHeader.Type.WithEcuId, 2);
    auto good = buildDltMessage("ECU1", 3, 0, 0, 3, [0x42]);

    auto format = new DltFormat();
    assert(scanAll(format, shortExtended ~ good) == [shortExtended.length]);
    assert(scanAll(format, shortEcuId ~ good) == [shortEcuId.length]);
    assert(format.recordAt(shortExtended ~ good, 0).length == 0, "not a record to decode");

    auto streamed = new DltFormat(false);
    const stream = shortExtended[StorageHeader.sizeof .. $] ~ good[StorageHeader.sizeof .. $];
    assert(scanAll(streamed, stream) == [shortExtended.length - StorageHeader.sizeof]);
}

@("DltFormat columns: counter, session ID and message ID are shown as DLT viewers commonly show them")
unittest
{
    import std.algorithm : map;
    import std.array : array;

    assert(new DltFormat().columns.map!(c => c.id).array == ["time", "timestamp", "counter",
        "ecu", "app", "ctx", "session", "type", "level", "msgid", "payload"]);
}

@("DltFormat.scanRecords: a length running past the end doesn't hide the records after it")
unittest
{
    auto broken = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3]);
    broken[StorageHeader.sizeof + 2 .. StorageHeader.sizeof + 4] = [0xFF, 0xFF];
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [4]);
    auto msg3 = buildDltMessage("ECU1", 3, 0, 0, 3, [5]);
    auto data = broken ~ msg2 ~ msg3;

    assert(scanAll(new DltFormat(), data) == [broken.length, broken.length + msg2.length]);

    // Without final_ the record may still be growing: wait for it
    size_t[4] offsets;
    const r = new DltFormat().scanRecords(data, 0, offsets[], false);
    assert(r.count == 0 && r.next == 0);
}

@("DltFormat.scanRecords: a length too long doesn't cover the records after it")
unittest
{
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [4]);
    auto msg3 = buildDltMessage("ECU1", 3, 0, 0, 3, [5]);
    // Ends inside msg3: the data goes on after the broken record
    const sound = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3]);
    const tooLong = cast(int)(sound.length - StorageHeader.sizeof + msg2.length + 5);
    auto broken = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3], tooLong);
    auto data = broken ~ msg2 ~ msg3;
    const expected = [0, broken.length, broken.length + msg2.length];

    auto format = new DltFormat();
    assert(scanAll(format, data) == expected);
    size_t[4] offsets;
    const r = format.scanRecords(data, 0, offsets[], false);
    assert(offsets[0 .. r.count] == expected, "a growing file too");

    // Cut where the next record starts, the same for the scan and for every row
    assert(format.recordAt(data, 0) == broken);
    LogMessage!wchar msg, soundMsg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(format.decode(soundMsg, sound));
    assert(msg.payloadText == soundMsg.payloadText, "nothing of the next records in the payload");
}

@("DltFormat.scanRecords: a length too long cut shorter than its headers is skipped")
unittest
{
    // The flags announce an extended header, the next record starts where it should be
    auto msg2 = buildDltMessage("ECU1", 2, 0, 0, 2, [4]);
    auto msg3 = buildDltMessage("ECU1", 3, 0, 0, 3, [5]);
    const tooLong = cast(int)(StandardHeader.sizeof + msg2.length + 5);
    auto broken = buildDltMessage("ECU1", 1, 0, StandardHeader.Type.UseExtendedHeader, 1, [], tooLong);
    auto data = broken ~ msg2 ~ msg3;

    auto format = new DltFormat();
    assert(scanAll(format, data) == [broken.length, broken.length + msg2.length]);
    assert(format.recordAt(data, 0).length == 0);
}

@("DltFormat.scanRecords: a length is trusted when the data ends or a header may follow")
unittest
{
    // A regression guard: it passed before the cut too, it fails if the cut is too eager
    auto msg = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3]);
    auto format = new DltFormat();

    // Nothing after the record, or the start of a header still being written
    foreach (tail; [cast(ubyte[]) [], cast(ubyte[]) "D", cast(ubyte[]) "DLT"])
        assert(format.recordAt(msg ~ tail, 0) == msg);

    // A length too short: the bytes after it hold no header, the record keeps its length
    auto good = buildDltMessage("ECU1", 2, 0, 0, 2, [4]);
    auto data = msg ~ cast(ubyte[]) "garbage" ~ good;
    assert(format.recordAt(data, 0) == msg);
    assert(scanAll(format, data) == [0, msg.length + "garbage".length]);
}

@("DltFormat.scanRecords: a length too long is cut at a storage header of version 2")
unittest
{
    import formats.dlt.testing_utils : BuildV2, storageV2;

    BuildV2 b;
    auto v2 = storageV2("S", 1, 0) ~ b.bytes();
    const sound = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3]);
    const tooLong = cast(int)(sound.length - StorageHeader.sizeof + v2.length);
    auto broken = buildDltMessage("ECU1", 1, 0, 0, 1, [1, 2, 3], tooLong);
    auto data = broken ~ v2 ~ cast(ubyte[]) "tail";

    assert(scanAll(new DltFormat(), data) == [0, broken.length]);
}

@("DltFormat.scanRecords: a record of an unknown protocol version")
unittest
{
    // Version 3 with the bits of an extended header and a length too short for it in version 1
    const ubyte version3 = 3 << 5 | StandardHeader.Type.UseExtendedHeader;
    auto record = buildDltMessage("ECU1", 1, 0, version3, 1);

    // After a storage header it is taken for bytes of a payload: no such version exists
    assert(scanAll(new DltFormat(), record).length == 0);
    // A stream has no choice: the record is kept, the decoder says it can't show it
    assert(scanAll(new DltFormat(false), record[StorageHeader.sizeof .. $]) == [0]);
}

// ─── Protocol and storage header version 2 ──────────────────────────────────

version (unittest)
{
    import formats.dlt.testing_utils : BuildV2, sampleV2Message;

    ubyte[] storageHeaderV2(const(char)[] ecuId)
    {
        ubyte[] bytes = cast(ubyte[]) "DLT\x02".dup;
        bytes ~= [0, 0, 0, 0, 1, 0, 0, 0, 0];
        bytes ~= cast(ubyte) ecuId.length;
        return bytes ~ cast(const(ubyte)[]) ecuId;
    }
}

@("DltFormat.scanRecords: version 2 records with storage headers of both versions")
unittest
{
    BuildV2 b;
    b.ecuId = "ECU1";
    b.payload = [1, 2, 3];
    auto v2 = storageHeaderV2("STORAGE") ~ b.bytes(); // a storage header of 21 bytes
    auto v1Storage = cast(ubyte[]) buildDltMessage("ECU1", 1, 0, 0, 1)[0 .. StorageHeader.sizeof] ~ b.bytes();
    auto v1 = buildDltMessage("ECU1", 2, 0, 0, 2, [4]);
    auto data = v2 ~ v1 ~ v1Storage ~ v2;

    auto format = new DltFormat();
    const offsets = [0, v2.length, v2.length + v1.length, v2.length + v1.length + v1Storage.length];
    assert(scanAll(format, data) == offsets);
    foreach (i, offset; offsets)
        assert(format.recordAt(data, offset).length == [v2, v1, v1Storage, v2][i].length);
}

@("DltFormat.scanRecords: version 2 records without storage header")
unittest
{
    BuildV2 b;
    b.payload = [9];
    auto data = sampleV2Message ~ b.bytes() ~ sampleV2Message;
    assert(scanAll(new DltFormat(false), data) == [0, 71, 71 + b.bytes().length]);
}

@("DltFormat.scanRecords: a version 2 record shorter than its header is skipped")
unittest
{
    BuildV2 broken;
    broken.ecuId = "ECU1";
    broken.length = 9; // ends inside the ECU ID
    BuildV2 good;
    auto data = storageHeaderV2("S") ~ broken.bytes() ~ storageHeaderV2("S") ~ good.bytes();

    const second = storageHeaderV2("S").length + broken.bytes().length;
    assert(scanAll(new DltFormat(), data) == [second]);
}

@("DltDetector: a version 2 storage header at the start is certain")
unittest
{
    BuildV2 b;
    assert(new DltDetector().detect("x.log", storageHeaderV2("ECU1") ~ b.bytes()).score == 1.0f);
}

@("DltFormat.scanRecords: a version 2 record with reserved values is kept and shown as invalid")
unittest
{
    auto reserved = sampleV2Message.dup;
    reserved[0] |= 0x03; // CNTI 3: the length is right, the content unknown
    auto data = storageHeaderV2("S") ~ reserved ~ storageHeaderV2("S") ~ sampleV2Message;

    auto format = new DltFormat();
    const first = storageHeaderV2("S").length + reserved.length;
    assert(scanAll(format, data) == [0, first]);

    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(msg.payloadText == "[invalid DLT version 2 header]"w);
}

@("findNextStorageHeader: a pattern not followed by a message of a known version is not a header")
unittest
{
    ubyte[] garbage = cast(ubyte[]) "text DLT\x02".dup ~ new ubyte[](9) ~ cast(ubyte[])[0, 0xE0, 0, 0, 0]
        ~ cast(ubyte[]) "DLT\x01".dup ~ new ubyte[](12) ~ cast(ubyte[])[0xE0, 0, 0, 4, 0, 0];
    assert(findNextStorageHeader(garbage).length == 0);
    assert(new DltDetector().detect("x.log", garbage).score == 0);

    auto msg = buildDltMessage("ECU1", 1, 0, 0, 1, [0x42]);
    auto data = garbage ~ msg;
    assert(findNextStorageHeader(data).ptr == &data[garbage.length]);

    // A header cut by the end of the data may still be one
    auto cut = garbage ~ msg[0 .. StorageHeader.sizeof];
    assert(findNextStorageHeader(cut).length == StorageHeader.sizeof);
}

@("DltFormat: a TransferringFormat, tells a message of a file sent in the log at its offset")
unittest
{
    import formats.dlt.testing_utils : VerboseArgs;

    const usual = buildDltMessage();
    const data = usual ~ VerboseArgs().str("FLFI").u32(7).str("FLFI").record();
    const format = cast(const(TransferringFormat)) new DltFormat();
    assert(format !is null);
    assert(format.marksOf(data, 0) == RecordMark.none && format.transferOf(data, 0).kind == TransferKind.none);
    const m = format.transferOf(data, usual.length);
    assert(format.marksOf(data, usual.length) == RecordMark.transfer && m.kind == TransferKind.end && m.serial == 7);
}

@("DltFormat.marksOf: a part, a message of a transfer, a usual record, in either version")
unittest
{
    import formats.dlt.header_v2 : ContentInfo;
    import formats.dlt.testing_utils : BuildV2, VerboseArgs, storageV2;

    const format = new DltFormat();
    ubyte marks(const(ubyte)[] record) => format.marksOf(record, 0);

    assert(marks(VerboseArgs().str("1/2: he").record()) == RecordMark.part);
    assert(marks(VerboseArgs(false).str("2/2: llo").record()) == RecordMark.part, "little-endian");
    assert(marks(VerboseArgs().str("FLFI").u32(7).str("FLFI").record()) == RecordMark.transfer);
    assert(marks(VerboseArgs().str("a text").record()) == RecordMark.none);
    {
        import std.array : replicate;
        import formats.dlt.parts : dltPieceLimits;

        const cut = "a".replicate(dltPieceLimits[$ - 1]);
        assert(marks(VerboseArgs().str(cut).record()) == RecordMark.part, "a piece cut at the limit");
        assert(marks(VerboseArgs().str(cut[0 .. $ - 1] ~ "\n").record()) == RecordMark.none, "a whole one");
        assert(marks(VerboseArgs().str(cut ~ "a").record()) == RecordMark.none, "over the limit");
    }
    assert(marks(VerboseArgs().str("FLFI").u32(7).record()) == RecordMark.none, "two arguments");
    assert(marks(buildDltMessage()) == RecordMark.none, "not verbose");

    BuildV2 part;
    part.appId = "APP1";
    part.ctxId = "CTX1";
    part.numberOfArguments = 1;
    part.payload = VerboseArgs(false).str("1/3: a").bytes;
    assert(marks(storageV2("ECU1", 1, 0) ~ part.bytes()) == RecordMark.part, "version 2");
    BuildV2 transfer = part;
    transfer.numberOfArguments = 3;
    transfer.payload = VerboseArgs(false).str("FLFI").u32(7).str("FLFI").bytes;
    assert(marks(storageV2("ECU1", 1, 0) ~ transfer.bytes()) == RecordMark.transfer, "version 2");
}

@("DltFormat: non-verbose messages decoded by the FIBEX of the format, if it has one")
unittest
{
    import formats.dlt.fibex : fibexOf, logFrame, parseFibex, textPdu, valuePdu;
    import formats.dlt.testing_utils : BuildV1, bytesOf;

    const fibex = parseFibex(fibexOf(textPdu("P_T", "Free size:") ~ valuePdu("P_U16", "S_UINT16", 2),
            logFrame("ID_11", "APP1", "CON1", "P_T", "P_U16")));
    BuildV1 r;
    r.extended = false;
    r.payload = bytesOf(11u) ~ bytesOf(cast(ushort) 42);
    const record = r.bytes();

    LogMessage!wchar msg;
    assert(new DltFormat(true, fibex).decode(msg, record));
    assert(msg.payloadText == "Free size: 42"w, "described by the FIBEX");
    // A regression guard: a format without FIBEX shows the message as before
    assert(new DltFormat().decode(msg, record));
    assert(msg.payloadText == "[11] 002A |.*"w, "no FIBEX: the ID and the bytes");
}

@("withFibex: the same storage header choice, decoding by the FIBEX given or by none")
unittest
{
    import formats.dlt.fibex : fibexOf, logFrame, parseFibex, textPdu;
    import formats.dlt.testing_utils : BuildV1, bytesOf;
    import formats.plain_text : PlainTextFormat;

    const fibex = parseFibex(fibexOf(textPdu("P_T", "Started"), logFrame("ID_3", "APP1", "CON1", "P_T")));
    BuildV1 r;
    r.extended = false;
    r.payload = bytesOf(3u);
    const record = r.bytes();

    assert(takesFibex(new DltFormat()) && !takesFibex(new PlainTextFormat()));
    auto described = cast(DltFormat) withFibex(new DltFormat(true), fibex);
    assert(described !is null && described.hasStorageHeader && described.fibex is fibex);
    LogMessage!wchar msg;
    assert(described.decode(msg, record) && msg.payloadText == "Started"w);

    auto stream = cast(DltFormat) withFibex(new DltFormat(false), fibex);
    assert(!stream.hasStorageHeader, "a stream stays a stream: the records are split the same way");

    auto plain = cast(DltFormat) withFibex(described, null);
    assert(plain.fibex is null && plain.decode(msg, record) && msg.payloadText == "[3]"w);
    assert(withFibex(new PlainTextFormat(), fibex) is null, "a format that takes no FIBEX");
}
