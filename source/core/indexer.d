module core.indexer;

import std.mmfile;
import std.stdio;
import std.datetime;
import core.dlt;
import std.algorithm : min;

/// Information about a single DLT message used for indexing
struct MsgInfo
{
    ulong offset;
    ushort length;
    ulong timestamp; // Timestamp from Storage Header (microseconds since epoch usually, or from Standard Header)
    uint ecuId; // Helper mapping needed later
}

class Indexer
{
    private MmFile _mmFile;
    private MsgInfo[] _index;

    this(string filePath)
    {
        // Map the file read-only, copy-on-write false (we only read)
        _mmFile = new MmFile(filePath, MmFile.Mode.read, 0, null);
    }

    @property const(MsgInfo)[] index() const pure nothrow @nogc
    {
        return _index;
    }

    @property ulong totalMessages() const pure nothrow @nogc
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
        ulong offset = 0;
        const void* data = _mmFile[].ptr;
        ulong size = _mmFile.length;

        while (offset < size)
        {
            // Check for Storage Header "DLT\01"
            if (size - offset < StorageHeader.sizeof)
                break;

            auto sh = cast(const(StorageHeader)*)(data + offset);
            if (sh.pattern != "DLT\01")
            {
                // Determine recovery strategy (search next pattern? for now assume valid DLT)
                // Simplest recovery: advance 1 byte
                offset++;
                continue;
            }

            ulong msgOffset = offset;
            ulong currentTimestamp = cast(ulong) sh.seconds * 1_000_000 + sh.microseconds;

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
            _index ~= MsgInfo(msgOffset, length, currentTimestamp, 0); // TODO: Parse ECU ID

            // Advance to next message (skip the rest of this known message)
            // Length in Standard Header is total index of the message EXCLUDING Storage Header?
            // "The Length field shall contain the length of the DLT message... header and payload"
            // It does NOT include Storage Header.

            offset += length;
        }
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
