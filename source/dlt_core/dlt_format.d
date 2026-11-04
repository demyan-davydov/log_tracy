module dlt_core.dlt_format;

import dlt_core.dlt_protocol;
import dlt_core.dlt_parser : parseDltItem;

import log_core.log_format;
import log_core.log_message : LogMessage;

import std.algorithm.comparison : max, min;

//! DLT messages, with a storage header (DLT files) or without one (streams).
//! Record layout: [ Storage Header ] Standard Header [ ... ] where the
//! standard header holds the length of the message without the storage header.
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
        return "DLT";
    }

    override size_t minRecordLength() const pure nothrow @nogc
    {
        return storageHeaderSize + StandardHeader.sizeof;
    }

    private size_t storageHeaderSize() const pure nothrow @nogc
    {
        return _hasStorageHeader ? StorageHeader.sizeof : 0;
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

            const length = recordLength(data[start .. $]);
            if (length == 0) // incomplete record at the end
            {
                pos = final_ ? data.length : start;
                break;
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

        const length = recordLength(buffer);
        return buffer[0 .. length];
    }

    override bool decode(ref LogMessage!wchar msg, const(ubyte)[] record) const nothrow @nogc
    {
        return parseDltItem!wchar(msg, record, _hasStorageHeader);
    }

    //! @returns the length of the record at the start of `buffer`, including
    //! the storage header, or 0 if the buffer ends before the record does
    private size_t recordLength(const(ubyte)[] buffer) const nothrow @nogc
    {
        const headerSize = storageHeaderSize;
        if (buffer.length < headerSize + StandardHeader.sizeof)
            return 0;

        auto standardHeader = cast(const(StandardHeader)*)(buffer.ptr + headerSize);
        // A corrupt length shorter than the standard header still moves on
        const size_t length = headerSize + max(standardHeader.nativeLength, StandardHeader.sizeof);
        return length <= buffer.length ? length : 0;
    }
}

//! Recognises DLT files by their storage header
final class DltDetector : FormatDetector
{
    override Detection detect(string path, const(ubyte)[] head) const
    {
        import std.path : extension;
        import std.uni : sicmp;

        if (startsWithStorageHeader(head))
            return Detection(1.0f);
        if (findNextStorageHeader(head).length != 0)
            return Detection(0.8f); // garbage before the first message
        if (sicmp(extension(path), ".dlt") == 0)
            return Detection(0.5f);
        // The only format so far: opens anything, as before.
        // TODO: 0 once plain text is the fallback
        return Detection(0.01f);
    }

    override LogFormat create(int variant, const(ubyte)[] head) const
    {
        return new DltFormat(true);
    }
}

//! @returns true if `buffer` starts with a complete storage header
private bool startsWithStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
{
    return buffer.length >= StorageHeader.sizeof && buffer[0 .. DLT_PATTERN.length] == DLT_PATTERN[];
}

//! @returns slice of original buffer starting from DLT header pattern (DLT\01)
//! or empty slice reffered to bufferEnd
//! @note The result slice will have at least StorageHeader.sizeof bytes,
//! otherwise the empty slice is returned
private const(ubyte)[] findNextStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
{
    if (buffer.length < StorageHeader.sizeof)
        return buffer[$ .. $];

    const(ubyte)* ptr = buffer.ptr;
    const(ubyte)* end = buffer.ptr + buffer.length - StorageHeader.sizeof + 1;

    // DLT header is 4 bytes "DLT\01".
    // This sequence do not contain repeated symbols,
    // so we can use simplier algorithm to search for it:
    // we do not to return to the start of the buffer
    // and search for the pattern from the start
    // we can just move forward and check each byte

    while (ptr < end)
    {
        if (*ptr++ != DLT_PATTERN[0])
            continue;

        if (*ptr != DLT_PATTERN[1])
            continue;
        ++ptr;

        if (*ptr != DLT_PATTERN[2])
            continue;
        ++ptr;

        if (*ptr != DLT_PATTERN[3])
            continue;

        ptr -= DLT_PATTERN.sizeof - 1;
        return ptr[0 .. buffer.ptr + buffer.length - ptr];
    }

    return buffer[$ .. $];
}

// ─── Test Helpers ──────────────────────────────────────────────────────────

version (unittest)
{
    import std.bitmanip : nativeToBigEndian;

    /// Build a minimal valid DLT message (StorageHeader + StandardHeader + payload)
    ubyte[] buildDltMessage(
        const(char)[4] ecuId = "ECU1",
        uint seconds = 1000,
        uint microseconds = 500,
        ubyte headerType = 0,
        ubyte messageCounter = 0,
        const(ubyte)[] payload = []
    )
    {
        ubyte[] msg;

        // Storage Header (16 bytes, little-endian)
        msg ~= cast(ubyte[]) DLT_PATTERN;
        msg ~= nativeToLE(seconds);
        msg ~= nativeToLE(microseconds);
        msg ~= cast(const(ubyte)[]) ecuId;

        // Standard Header (4 bytes)
        msg ~= headerType;
        msg ~= messageCounter;

        ushort totalLength = cast(ushort)(StandardHeader.sizeof + payload.length);
        ubyte[2] lenBE = nativeToBigEndian!ushort(totalLength);
        msg ~= lenBE[];

        // Payload
        msg ~= payload;

        return msg;
    }

    /// Convert uint to little-endian bytes
    private ubyte[4] nativeToLE(uint val) pure nothrow @nogc
    {
        version (LittleEndian)
            return *cast(ubyte[4]*)&val;
        else
            return [
                cast(ubyte)(val & 0xFF),
                cast(ubyte)((val >> 8) & 0xFF),
                cast(ubyte)((val >> 16) & 0xFF),
                cast(ubyte)((val >> 24) & 0xFF)
            ];
    }

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
    buf[3] = '\02'; // wrong trailing byte
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
    import dlt_core.dlt_fields;

    ubyte headerType = StandardHeader.Type.UseExtendedHeader;
    ubyte[ExtendedHeader.sizeof] extHeader;
    extHeader[0] = 0x01; // messageInfo: verbose
    extHeader[1] = 0; // numberOfArguments
    extHeader[2 .. 6] = cast(ubyte[4]) "APP1";
    extHeader[6 .. 10] = cast(ubyte[4]) "CTX1";
    auto data = buildDltMessage("ECU1", 400, 0, headerType, 5, extHeader[]);

    auto format = new DltFormat();
    LogMessage!wchar msg;
    assert(format.decode(msg, format.recordAt(data, 0)));
    assert(msg.ecuId == "ECU1"w);
    assert(msg.appId == "APP1"w);
    assert(msg.ctxId == "CTX1"w);
    assert(msg.timestampSeconds == 400);
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
    assert(detector.detect("x.DLT", text).score == 0.5f);
    assert(detector.detect("x.log", text).score < 0.5f);
}
