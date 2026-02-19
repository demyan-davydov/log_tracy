module dlt_core.dlt_source;

import std.stdio;
import std.mmfile;
import utils.mmap_array;
import dlt_core.dlt_protocol;

//! Represent source file of DLT document
//! Allow to iterate over messages in the file

struct DltSource
{
    private MmFile _mmFile;
    private const(char)* _dataBegin;
    private const(char)[] _rest; // slice for not readed part of mmFile content
    private const bool _hasStorageHeader;
    //private MmapArray!(size_t) _msgOffsets;
    //private MmapArray!(uint32_t) _filteredIndices;

    @disable this();
    @disable this(ref DltSource);
    @disable void opAssign(ref DltSource);

    this(string filePath, bool containsStorageHeader = true)
    {
        _mmFile = new MmFile(filePath, MmFile.Mode.read, 0, null);
        _rest = cast(const(char)[]) _mmFile[0 .. _mmFile.length];
        _dataBegin = _rest.ptr;
        _hasStorageHeader = containsStorageHeader;

        //const size_t capacity = 1 + _mmFile.length / (StorageHeader.sizeof + StandardHeader.sizeof);
        //_msgOffsets = MmapArray!(size_t)(capacity);
    }

    ~this()
    {
        // _mmFile.close();
    }

    void rewind()
    {
        _rest = cast(const(char)[]) _mmFile[0 .. _mmFile.length];
    }

    /*void close() pure @nogc nothrow
    {
        _mmFile.close();
        _rest = [];
        _dataBegin = _rest.ptr;
    }*/

    size_t length() const pure nothrow @nogc @property
    {
        return _rest.length;
    }

    bool hasStorageHeader() const pure nothrow @nogc @property
    {
        return _hasStorageHeader;
    }

    const(char)[] popMessage() pure @nogc nothrow
    {
        if (hasStorageHeader)
        {
            _rest = findNextStorageHeader(_rest);
        }

        const(char)[] result = _rest[0 .. 0];

        if (_rest.length > StorageHeader.sizeof)
        {
            _rest = _rest[StorageHeader.sizeof .. $];
            if (_rest.length >= StandardHeader.sizeof)
            {
                auto standardHeader = cast(const(StandardHeader)*) _rest.ptr;
                const ushort length = standardHeader.nativeLength;

                _rest = _rest[length .. $];
                result = result.ptr[0 .. _rest.ptr - result.ptr];
            }
        }

        return result;
    }

    /*
    LogItem fetchLogItem(const(char)* messageBegin, ref MessageBuffer buffer) const pure @nogc nothrow
    in
    {
        assert(messageBegin >= _dataBegin && messageBegin < _dataBegin + length);
    }
    body
    {
        // todo
    }

    LogItem fetchLogItem(size_t offset, ref MessageBuffer buffer) const pure @nogc nothrow
    {
        return fetchLogItem(_dataBegin + offset, buffer);
    }*/
}

//! @returns slice of original buffer starting from DLT header pattern (DLT\01) 
//! or empty slice reffered to bufferEnd
//! @note The result slice will have at least StorageHeader.sizeof bytes, 
//! otherwise the empty slice is returned
const(char)[] findNextStorageHeader(const(char)[] buffer) pure @nogc nothrow
in
{
    // assert(buffer.length >= StorageHeader.sizeof);
}
out
{
    // assert(result.length >= StorageHeader.sizeof || result.length == 0);
}
body
{
    const(char)* ptr = buffer.ptr;
    const(char)* end = buffer.ptr + buffer.length - StorageHeader.sizeof + 1;

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
    import std.file : write, remove, tempDir;
    import std.path : buildPath;

    /// Build a minimal valid DLT message (StorageHeader + StandardHeader + payload)
    private ubyte[] buildDltMessage(
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

    /// Helper: write data to a temp file, return path
    private string writeTempDlt(const(ubyte)[] data, string name = "test.dlt")
    {
        string path = buildPath(tempDir(), name);
        write(path, data);
        return path;
    }
}

// ─── findNextStorageHeader tests ───────────────────────────────────────────

@("findNextStorageHeader: finds header at start of buffer")
unittest
{
    char[StorageHeader.sizeof] buf;
    buf[0 .. 4] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == buf.ptr);
    assert(result.length == StorageHeader.sizeof);
}

@("findNextStorageHeader: finds header after garbage bytes")
unittest
{
    char[] buf;
    buf.length = 10 + StorageHeader.sizeof;
    buf[] = 'X';
    buf[10 .. 14] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == &buf[10]);
}

@("findNextStorageHeader: returns empty slice when no header found")
unittest
{
    char[StorageHeader.sizeof] buf = 'X';
    auto result = findNextStorageHeader(buf[]);
    assert(result.length == 0);
}

@("findNextStorageHeader: partial DLT pattern is not matched")
unittest
{
    char[] buf;
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
    char[] buf;
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
    char[3] buf = "DLT";
    auto result = findNextStorageHeader(buf[]);
    assert(result.length == 0);
}

@("findNextStorageHeader: header at the very end of buffer")
unittest
{
    char[] buf;
    buf.length = 20 + StorageHeader.sizeof;
    buf[] = 'X';
    buf[20 .. 24] = DLT_PATTERN;
    auto result = findNextStorageHeader(buf[]);
    assert(result.ptr == &buf[20]);
}

// ─── DltSource construction tests ──────────────────────────────────────────

@("DltSource: constructs from valid DLT file")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg);
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    assert(source.length == msg.length);
    assert(source.hasStorageHeader == true);
}

@("DltSource: constructs with containsStorageHeader=false")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg, "test_no_sh.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path, false);
    assert(source.hasStorageHeader == false);
}

@("DltSource: rewind resets to beginning")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg, "test_rewind.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    source.popMessage();
    assert(source.length < msg.length || source.length == 0);

    source.rewind();
    assert(source.length == msg.length);
}

// ─── DltSource.popMessage tests ────────────────────────────────────────────

@("DltSource.popMessage: returns message slice from single-message file")
unittest
{
    ubyte[] payload = [0x01, 0x02, 0x03, 0x04];
    auto msg = buildDltMessage("ECU1", 1000, 0, 0, 1, payload);
    auto path = writeTempDlt(msg, "test_pop_single.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    auto result = source.popMessage();
    assert(result.length == msg.length);
}

@("DltSource.popMessage: iterates over multiple messages")
unittest
{
    ubyte[] payload1 = [0xAA, 0xBB];
    ubyte[] payload2 = [0xCC, 0xDD, 0xEE];

    auto msg1 = buildDltMessage("ECU1", 100, 0, 0, 1, payload1);
    auto msg2 = buildDltMessage("ECU2", 200, 0, 0, 2, payload2);

    ubyte[] combined;
    combined ~= msg1;
    combined ~= msg2;

    auto path = writeTempDlt(combined, "test_pop_multi.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);

    auto first = source.popMessage();
    assert(first.length == msg1.length);

    auto second = source.popMessage();
    assert(second.length == msg2.length);
}

@("DltSource.popMessage: returns empty on exhausted source")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg, "test_pop_exhausted.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    source.popMessage();

    auto result = source.popMessage();
    assert(result.length == 0);
}

@("DltSource.popMessage: skips garbage before valid header")
unittest
{
    ubyte[] garbage = [0xFF, 0xFE, 0xFD, 0xFC, 0xFB];
    auto msg = buildDltMessage("ECU1", 300, 0, 0, 1, [0x42]);

    ubyte[] combined;
    combined ~= garbage;
    combined ~= msg;

    auto path = writeTempDlt(combined, "test_pop_garbage.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    auto result = source.popMessage();
    assert(result.length == msg.length);
}

@("DltSource.popMessage: handles file with no valid DLT headers")
unittest
{
    ubyte[] garbage = [
        0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8,
        0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2, 0xF1, 0xF0,
        0xEF, 0xEE, 0xED, 0xEC
    ];
    auto path = writeTempDlt(garbage, "test_pop_no_headers.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    auto result = source.popMessage();
    assert(result.length == 0);
}

@("DltSource.popMessage: message with extended header")
unittest
{
    ubyte headerType = StandardHeader.Type.UseExtendedHeader;

    ubyte[ExtendedHeader.sizeof] extHeader;
    extHeader[0] = 0x01; // messageInfo: verbose
    extHeader[1] = 2; // numberOfArguments
    extHeader[2 .. 6] = cast(ubyte[4]) "APP1";
    extHeader[6 .. 10] = cast(ubyte[4]) "CTX1";

    ubyte[] payload = [0x11, 0x22, 0x33];
    ubyte[] fullPayload;
    fullPayload ~= extHeader[];
    fullPayload ~= payload;

    auto msg = buildDltMessage("ECU1", 400, 0, headerType, 5, fullPayload);
    auto path = writeTempDlt(msg, "test_pop_ext.dlt");
    scope (exit)
        remove(path);

    auto source = DltSource(path);
    auto result = source.popMessage();
    assert(result.length == msg.length);

    auto stdHdr = cast(const(StandardHeader)*)(result.ptr + StorageHeader.sizeof);
    assert(stdHdr.useExtendedHeader());
    assert(stdHdr.messageCounter == 5);
}
