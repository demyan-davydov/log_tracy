module dlt_core.indexer;

import dlt_core.dlt_protocol;
import dlt_core.log_item;

import std.mmfile;
import std.stdio;
import std.algorithm : min;
import std.stdint;

/// Information about a single DLT message used for indexing
struct MsgInfo
{
    ulong offset;
    ushort length;
    ulong timestamp; // Timestamp from Storage Header (microseconds since epoch usually, or from Standard Header)
    uint32_t ecuId; // Helper mapping needed later
}

//! @returns slice of original buffer containing DLT header (DLT\01) 
//! or empty slice reffered to bufferEnd
const(char)[] findHeaderPattern(const(char)[] buffer)
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
        return ptr[0 .. DLT_PATTERN.sizeof];
    }

    return buffer[$ .. $];
}

import dlt_core.file_stream;
import dlt_core.stream;

private bool skipDltHeader(InputStream stream)
{
    char currSymbol = 0;
    while (!stream.empty())
    {
        if (currSymbol != DLT_PATTERN[0])
        {
            if (!stream.pop!char(currSymbol))
                return false;
            if (currSymbol != DLT_PATTERN[0])
                continue;
        }

        if (!stream.pop!char(currSymbol))
            return false;
        if (currSymbol != DLT_PATTERN[1])
            continue;
        if (!stream.pop!char(currSymbol))
            return false;
        if (currSymbol != DLT_PATTERN[2])
            continue;
        if (!stream.pop!char(currSymbol))
            return false;
        if (currSymbol != DLT_PATTERN[3])
            continue;

        return true;
    }

    return false;
}

class Indexer2
{
    private InputStream _stream;
    private MsgInfo[] _index;
    private ulong _processedSize;
    private ulong _totalSize;

    this(string filePath)
    {
        _stream = new FileStream(filePath);
        _totalSize = 1000; //_stream.size();
    }

    @property const(MsgInfo)[] index() const pure nothrow @nogc
    {
        return _index;
    }

    @property size_t totalMessages() const pure nothrow @nogc
    {
        return _index.length;
    }

    const(ubyte[]) getSlice(ulong offset, size_t length)
    {
        if (offset + length > _totalSize)
            return null;
        _stream.seek(offset);
        ubyte[] result = new ubyte[length];
        return _stream.popArrayOrThrow(result);
    }

    void scan()
    {
        //size_t index = 0;
        //_fileStream.rewind();
        _processedSize = 0;
        _index = [];
        while (!_stream.empty())
        {
            if (!skipDltHeader(_stream))
            {
                writeln("Failed to skip DLT header. File size: ", _totalSize);
                break;
            }

            StorageHeader storageHeader;
            if (!_stream.pop!(StorageHeader)(storageHeader))
            {
                writeln("Failed to read storage header. File size: ", _totalSize);
                break;
            }
            const ulong msgOffset = _stream.position() - StorageHeader.sizeof;
            const ulong currentTimestamp = cast(ulong) storageHeader.seconds * 1_000_000 + storageHeader
                .microseconds;

            StandardHeader standardHeader;
            if (!_stream.pop!(StandardHeader)(standardHeader))
            {
                writeln("Failed to read standard header. File size: ", _totalSize);
                break;
            }

            ushort length = bigEndianToNative(standardHeader.length);

            // Create Index Entry
            // ECU ID is char[4]. We cast it to uint for storage in MsgInfo.
            const uint32_t ecuId = *cast(const(uint32_t)*) storageHeader.ecuId.ptr;
            _index ~= MsgInfo(msgOffset, length, currentTimestamp, ecuId);
            _processedSize = _stream.position();
            _stream.skip(length);
        }
    }
}

class Indexer
{
    private MmFile _mmFile;
    private MsgInfo[] _index;
    private ulong _processedSize;
    private ulong _totalSize;

    this(string filePath)
    {
        // Map the file read-only, copy-on-write false (we only read)
        _mmFile = new MmFile(filePath, MmFile.Mode.read, 0, null);
        _totalSize = _mmFile.length;
    }

    @property const(MsgInfo)[] index() const pure nothrow @nogc
    {
        return _index;
    }

    @property size_t totalMessages() const pure nothrow @nogc
    {
        return _index.length;
    }

    /// Get raw slice of data from file
    const(ubyte[]) getSlice(ulong offset, size_t length)
    {
        if (offset + length > _mmFile.length)
            return null;
        return cast(const(ubyte[])) _mmFile[offset .. offset + length];
    }

    /// Scan the file and build the index
    void scan()
    {
        import std.datetime.stopwatch;

        auto sw = StopWatch(AutoStart.yes);
        scope (exit)
        {
            writeln("scan time: ", sw.peek.total!"msecs", " ms");
        }

        ulong offset = 0;
        const void* data = _mmFile[].ptr;
        const ulong size = _mmFile.length;
        const(char)* dataChar = cast(const(char)*) data;

        while (offset < size)
        {
            // Check for Storage Header "DLT\01"
            if (size - offset < StorageHeader.sizeof)
                break;

            // find next header
            auto nextHeader = findHeaderPattern(dataChar[offset .. size]);
            if (nextHeader.length == 0)
                break;

            auto sh = cast(const(StorageHeader)*) nextHeader.ptr;

            offset += nextHeader.ptr - (dataChar + offset);

            const ulong msgOffset = offset;
            const ulong currentTimestamp = cast(ulong) sh.seconds * 1_000_000 + sh.microseconds;

            offset += StorageHeader.sizeof;

            // Check for Standard Header
            if (size - offset < StandardHeader.sizeof)
                break;
            auto stdHdr = cast(const(StandardHeader)*)(data + offset);

            // Parse length (big endian usually in DLT, assume NATIVE for now or need bswap)
            // TODO: Handle Endianness properly based on system and file? 
            // DLT standard says Standard Header fields are Big Endian? 
            // Actually Storage Header is usually Little Endian (x86).
            // Standard Header fields are Big Endian.

            ushort length = bigEndianToNative(stdHdr.length);

            // Create Index Entry
            // ECU ID is char[4]. We cast it to uint for storage in MsgInfo.
            const uint32_t ecuId = *cast(const(uint32_t)*) sh.ecuId.ptr;
            _index ~= MsgInfo(msgOffset, length, currentTimestamp, ecuId);

            // Advance to next message (skip the rest of this known message)
            // Length in Standard Header is total index of the message EXCLUDING Storage Header?
            // "The Length field shall contain the length of the DLT message... header and payload"
            // It does NOT include Storage Header.

            offset += length;
            _processedSize = offset;
        }
        _processedSize = _totalSize;
    }

    int getProgress() const
    {
        if (_totalSize == 0)
            return 100;
        return cast(int)((_processedSize * 100) / _totalSize);
    }
}

// Helper for endianness
private ushort bigEndianToNative(ushort val) pure nothrow @nogc
{
    version (BigEndian)
        return val;
    else
        return cast(ushort)((val >> 8) | (val << 8));
}

// test findHeaderPattern
unittest
{
    const(char)[] data1 = "DLT\01___________________";
    assert(findHeaderPattern(data1).ptr == data1.ptr);

    const(char)[] data2 = "--DLT\01___________________";
    assert(findHeaderPattern(data2).ptr == data2.ptr + 2);

    const(char)[] data3 = "DLL\01___________________";
    assert(findHeaderPattern(data3).ptr == data3.ptr + data3.length);

    // 1 letter of prefix
    const(char)[] data4 = "DDLT\01___________________";
    assert(findHeaderPattern(data4).ptr == data4.ptr + 1);

    // 2 letters of prefix
    const(char)[] data5 = "DLDLT\01___________________";
    assert(findHeaderPattern(data5).ptr == data5.ptr + 2);

    // 3 letters of prefix
    const(char)[] data6 = "DLTDLT\01___________________";
    assert(findHeaderPattern(data6).ptr == data6.ptr + 3);
}
