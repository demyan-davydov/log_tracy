module formats.dlt.format;

import formats.dlt.protocol;
import formats.dlt.parser : parseDltItem;
import formats.dlt.header_v2 : HeaderV2, HeaderV2Status, baseHeaderV2Size, messageLengthV2,
    protocolVersion, readHeaderV2;

import log_core.log_format;
import log_core.log_message : LogMessage, TimeKind;
import formats.dlt.fields : DltField;

import std.algorithm.comparison : max, min;

//! How the user and the settings know DltFormat
enum FormatInfo dltFormatInfo = FormatInfo("dlt", "DLT", "DLT");

//! DLT messages, with a storage header (DLT files) or without one (streams).
//! Record layout: [ Storage Header ] Standard Header [ ... ] where the
//! standard header holds the length of the message without the storage header.
//! Both versions of the protocol and of the storage header, mixed in any way.
final class DltFormat : LogFormat
{
    private immutable bool _hasStorageHeader;

    //! The most bytes scanRecords() skips looking for a storage header before
    //! returning control to the caller
    enum size_t maxHeaderScan = 1024 * 1024;

    this(bool hasStorageHeader = true) pure nothrow @nogc @safe
    {
        _hasStorageHeader = hasStorageHeader;
    }

    bool hasStorageHeader() const pure nothrow @nogc @property
    {
        return _hasStorageHeader;
    }

    override string name() const pure nothrow @nogc
    {
        return dltFormatInfo.name;
    }

    private static immutable ColumnInfo[] _columns = [
        ColumnInfo("time", "Time", ColumnKind.Time, -1, 120, TimeKind.Absolute),
        ColumnInfo("timestamp", "Timestamp", ColumnKind.Duration, DltField.Timestamp, 150,
            TimeKind.None, 10_000),
        ColumnInfo("counter", "Count", ColumnKind.Integer, DltField.Counter, 45),
        ColumnInfo("ecu", "EcuId", ColumnKind.Text, DltField.EcuId, 60),
        ColumnInfo("app", "AppId", ColumnKind.Text, DltField.AppId, 60),
        ColumnInfo("ctx", "CtxId", ColumnKind.Text, DltField.CtxId, 60),
        ColumnInfo("session", "SessionId", ColumnKind.Integer, DltField.SessionId, 70),
        ColumnInfo("type", "Type", ColumnKind.Enum, DltField.Type, 60,
            TimeKind.None, 0, ["LOG", "APP", "NW", "CTRL"]),
        ColumnInfo("level", "Level", ColumnKind.Level, -1, 60),
        ColumnInfo("msgid", "MsgId", ColumnKind.Integer, DltField.MessageId, 70),
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
        return parseDltItem!wchar(msg, record, _hasStorageHeader);
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
        if (version_ == 2)
        {
            if (message.length < baseHeaderV2Size)
                return layout;
            length = max(messageLengthV2(message), baseHeaderV2Size);
        }
        else
        {
            if (message.length < StandardHeader.sizeof)
                return layout;
            length = max((cast(const(StandardHeader)*) message.ptr).nativeLength, StandardHeader.sizeof);
        }
        if (storage + length > buffer.length)
            return layout;

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
            layout.coversHeaders = standardHeader.nativeLength >= standardHeader.fullHeaderAndExtendedHeaderSize();
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

@("DltFormat columns: counter, session ID and message ID are shown like in dlt-viewer")
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
    import formats.dlt.testing_utils : BuildV2, dltViewerTestFile;

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
    auto data = dltViewerTestFile ~ b.bytes() ~ dltViewerTestFile;
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
    auto reserved = dltViewerTestFile.dup;
    reserved[0] |= 0x03; // CNTI 3: the length is right, the content unknown
    auto data = storageHeaderV2("S") ~ reserved ~ storageHeaderV2("S") ~ dltViewerTestFile;

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
