module dlt_core.dlt_source;

import std.stdio;
import utils.mapped_file : MappedFile;
import utils.mmap_array;
import dlt_core.dlt_protocol;

//! Represent source file of DLT document
//! Allow to iterate over messages in the file

interface DltSource
{
    DltSourceRange range() const pure nothrow @nogc @property;
    size_t overallLength() const pure nothrow @nogc @property;
    bool hasStorageHeader() const pure nothrow @nogc @property;
    //! true once the file can't be read any more (e.g. its disk was removed);
    //! its content reads as zeros from then on
    bool lost() const nothrow @nogc @property;
    const(ubyte)[] getMessage(size_t offset) const pure @nogc nothrow;
}

final class DltSourceFile : DltSource
{
    private MappedFile _file;
    private const(ubyte)* _dataBegin;
    private const(ubyte)* _dataEnd;
    private const bool _hasStorageHeader;

    @disable this();
    @disable this(ref DltSourceFile);
    @disable void opAssign(ref DltSourceFile);

    this(string filePath, bool containsStorageHeader = true)
    {
        _file = MappedFile(filePath);
        _dataBegin = _file.data.ptr;
        _dataEnd = _dataBegin + _file.data.length;
        _hasStorageHeader = containsStorageHeader;
    }

    ~this()
    {
        _file.close();
    }

    DltSourceRange range() const pure nothrow @nogc @property
    {
        const(ubyte)[] restArray = _dataBegin[0 .. overallLength];
        return DltSourceRange(restArray, _hasStorageHeader);
    }

    //! @returns the length of the file
    size_t overallLength() const pure nothrow @nogc @property
    {
        return _dataEnd - _dataBegin;
    }

    override bool lost() const nothrow @nogc @property
    {
        return _file.lost;
    }

    //! @returns true if the source file contains storage header
    bool hasStorageHeader() const pure nothrow @nogc @property
    {
        return _hasStorageHeader;
    }

    //! @returns slice of original buffer starting from DLT header pattern (DLT\01) 
    //! or empty slice reffered to bufferEnd
    //! @note The result slice will have at least StorageHeader.sizeof bytes, 
    //! otherwise the empty slice is returned
    const(ubyte)[] getMessage(size_t offset) const pure @nogc nothrow
    {
        const(ubyte)[] buffer = _dataBegin[offset .. overallLength];

        if (hasStorageHeader)
        {
            buffer = findNextStorageHeader(buffer);
        }

        const(ubyte)[] result = buffer[0 .. 0];

        if (buffer.length > StorageHeader.sizeof)
        {
            buffer = buffer[StorageHeader.sizeof .. $];
            if (buffer.length >= StandardHeader.sizeof)
            {
                auto standardHeader = cast(const(StandardHeader)*) buffer.ptr;
                const ushort length = standardHeader.nativeLength;

                buffer = buffer[length .. $];
                result = result.ptr[0 .. buffer.ptr - result.ptr];
            }
        }

        return result;
    }
}

//! @returns slice of original buffer starting from DLT header pattern (DLT\01) 
//! or empty slice reffered to bufferEnd
//! @note The result slice will have at least StorageHeader.sizeof bytes, 
//! otherwise the empty slice is returned
private const(ubyte)[] findNextStorageHeader(const(ubyte)[] buffer) pure @nogc nothrow
in
{
    //debug assert(buffer.length >= StorageHeader.sizeof);
}
out
{
    //debug assert(buffer.length >= StorageHeader.sizeof || buffer.length == 0);
}
body
{
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

// This struct refers to a part of the source file
// It is valid only for the lifetime of the DltSource object
struct DltSourceRange
{
    /// Every pop() consumes at least this many bytes, so a source of N bytes
    /// holds at most N / minMessageLength messages.
    enum size_t minMessageLength = StorageHeader.sizeof;

    private const(ubyte)* _dataBegin;
    private const(ubyte)* _dataEnd;
    private const(ubyte)[] _rest; // slice for not readed part of mmFile content
    private const bool _hasStorageHeader;

    this(const(ubyte)[] rest, bool hasStorageHeader) pure nothrow @nogc
    {
        _rest = rest;
        _dataBegin = _rest.ptr;
        _dataEnd = _dataBegin + _rest.length;
        _hasStorageHeader = hasStorageHeader;
    }

    bool hasNext() pure @nogc nothrow @property
    {
        return _rest.length > 0;
    }

    bool hasStorageHeader() const pure @nogc nothrow @property
    {
        return _hasStorageHeader;
    }

    // byte offset of the current message in the source file
    size_t offset() const pure @nogc nothrow @property
    {
        return _rest.ptr - _dataBegin;
    }

    size_t overallLength() const pure @nogc nothrow @property
    {
        return _dataEnd - _dataBegin;
    }

    size_t length() const pure @nogc nothrow @property
    {
        return _rest.length;
    }

    const(ubyte)[] pop() pure @nogc nothrow
    {
        if (_hasStorageHeader)
        {
            _rest = findNextStorageHeader(_rest);
        }

        const(ubyte)[] result = _rest[0 .. 0];

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
}

// ─── Test Helpers ──────────────────────────────────────────────────────────

version (unittest)
{
    import std.bitmanip : nativeToBigEndian;
    import std.file : write, remove, tempDir;
    import std.path : buildPath;
    import std.typecons : scoped;

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

// ─── DltSourceFile construction tests ──────────────────────────────────────────

@("DltSourceFile: constructs from valid DLT file")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg);
    scope (exit)
        remove(path);

    auto source = scoped!DltSourceFile(path);
    assert(source.overallLength == msg.length);
    assert(source.hasStorageHeader == true);
}

@("DltSourceFile: constructs with containsStorageHeader=false")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg, "test_no_sh.dlt");
    scope (exit)
        remove(path);

    auto source = scoped!DltSourceFile(path, false);
    assert(source.hasStorageHeader == false);
}

// ─── DltSourceRange.pop tests ────────────────────────────────────────────

@("DltSourceRange.pop: returns message slice from single-message file")
unittest
{
    ubyte[] payload = [0x01, 0x02, 0x03, 0x04];
    auto msg = buildDltMessage("ECU1", 1000, 0, 0, 1, payload);
    auto path = writeTempDlt(msg, "test_pop_single.dlt");
    scope (exit)
        remove(path);

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();
    auto result = range.pop();
    assert(result.length == msg.length);
}

@("DltSourceRange.pop: iterates over multiple messages")
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

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();

    auto first = range.pop();
    assert(first.length == msg1.length);

    auto second = range.pop();
    assert(second.length == msg2.length);
}

@("DltSourceRange.pop: returns empty on exhausted source")
unittest
{
    auto msg = buildDltMessage();
    auto path = writeTempDlt(msg, "test_pop_exhausted.dlt");
    scope (exit)
        remove(path);

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();
    range.pop();

    auto result = range.pop();
    assert(result.length == 0);
}

@("DltSourceRange.pop: skips garbage before valid header")
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

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();
    auto result = range.pop();
    assert(result.length == msg.length);
}

@("DltSourceRange.pop: handles file with no valid DLT headers")
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

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();
    auto result = range.pop();
    assert(result.length == 0);
}

@("DltSourceRange.pop: message with extended header")
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

    auto source = scoped!DltSourceFile(path);
    auto range = source.range();
    auto result = range.pop();
    assert(result.length == msg.length);

    auto stdHdr = cast(const(StandardHeader)*)(result.ptr + StorageHeader.sizeof);
    assert(stdHdr.useExtendedHeader());
    assert(stdHdr.messageCounter == 5);
}

