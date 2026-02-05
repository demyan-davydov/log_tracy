module core.dlt;

import std.bitmanip;

// DLT Data Structures

/// The storage header used in DLT files (16 bytes)
struct StorageHeader
{
align(1):
    char[4] pattern; // "DLT\01"
    uint seconds;
    uint microseconds;
    char[4] ecuId;
}

/// Standard Header Flags
enum HeaderType : ubyte
{
    UseExtendedHeader = 1 << 0,
    MostSignificantByteFirst = 1 << 1,
    WithEcuId = 1 << 2,
    WithSessionId = 1 << 3,
    WithTimestamp = 1 << 4,
    VersionMask = 0xE0
}

/// Fixed part of the Standard Header (4 bytes)
struct StandardHeader
{
align(1):
    ubyte headerType;
    ubyte messageCounter;
    ushort length; // Total length of the message
}

/// Extended Header (optional, 10 bytes)
struct ExtendedHeader
{
align(1):
    ubyte messageInfo;
    ubyte numberOfArguments;
    ubyte[4] applicationId;
    ubyte[4] contextId;
}

/// Message Info extended header field details
enum MessageInfo : ubyte
{
    Verbose = 1 << 0,
    TypeMask = 0x0E, // Bits 1-3
    // ... Type definitions
}

enum DltType : ubyte
{
    Log = 0x0,
    AppTrace = 0x1,
    NwTrace = 0x2,
    Control = 0x3
}

enum LogLevel : ubyte
{
    Fatal = 0x1,
    Error = 0x2,
    Warn = 0x3,
    Info = 0x4,
    Debug = 0x5,
    Verbose = 0x6
}

/// Type Info flags for Verbose arguments
enum TypeInfoFlags : uint
{
    TypeBoolean = 1 << 4,
    TypeSigned = 1 << 5,
    TypeUnsigned = 1 << 6,
    TypeFloat = 1 << 7,
    TypeString = 1 << 8,
    TypeRaw = 1 << 9,
    VariableInfo = 1 << 11,
    FixedPoint = 1 << 12,
    TypeTraceInfo = 1 << 13,
    TypeStruct = 1 << 14,
    StringCodingMask = 0x00000007 << 15, // Bits 15-17
    StringCodingASCII = 0 << 15,
    StringCodingUTF8 = 1 << 15
}

/// Helper to check if extended header is present
bool useExtendedHeader(ubyte ht) pure nothrow @nogc
{
    return (ht & HeaderType.UseExtendedHeader) != 0;
}

/// Helper to get Log Level from Extended Header Message Info
LogLevel getLogLevel(ubyte info) pure nothrow @nogc
{
    // Bit 0: Verbose.
    if (info & MessageInfo.Verbose)
    {
        // Verbose: Log Level is in bits 4..6 of info (Wait, standard says Message Type Info?)
        // Standard:
        // Byte 0: Mesage Info
        //   Bit 0: VERB (Verbose)
        //   Bit 1-3: MST (Message Type)
        //   Bit 4-7: MTIN (Message Type Info) -> This contains Log Level if MST=Logic
        return cast(LogLevel)((info >> 4) & 0x0F);
    }
    return LogLevel.Info; // Default/Unknown for Non-Verbose
}

/// Calculate the full header length (Standard + Extras + Extended)
uint getHeaderSize(const(ubyte)* ptr) pure nothrow @nogc
{
    // Ptr points to Standard Header (after Storage Header)
    const auto sh = cast(const(StandardHeader)*) ptr;
    uint size = StandardHeader.sizeof;

    const ubyte ht = sh.headerType;

    if (ht & HeaderType.WithEcuId)
        size += 4;
    if (ht & HeaderType.WithSessionId)
        size += 4;
    if (ht & HeaderType.WithTimestamp)
        size += 4;

    if (ht & HeaderType.UseExtendedHeader)
        size += ExtendedHeader.sizeof;

    return size;
}

/// Helper to read integers with correct endianness
T readValue(T)(const(ubyte)[] buffer, bool msbf) pure nothrow @nogc
{
    import std.bitmanip : bigEndianToNative, littleEndianToNative;

    if (buffer.length < T.sizeof)
        return T.init;

    ubyte[T.sizeof] tmp = buffer[0 .. T.sizeof];
    if (msbf)
        return bigEndianToNative!T(tmp);
    else
        return littleEndianToNative!T(tmp);
}

/// Extract Message ID from Non-Verbose message (returns 0 if not found/verbose)
uint peekMessageId(const(ubyte)* ptr) pure nothrow @nogc
{
    // Ptr points to Standard Header
    const auto sh = cast(const(StandardHeader)*) ptr;
    const ubyte ht = sh.headerType;
    const bool msbf = (ht & HeaderType.MostSignificantByteFirst) != 0;

    // Calculate header size (Standard + Extras + Extended)
    uint offset = StandardHeader.sizeof;
    if (ht & HeaderType.WithEcuId)
        offset += 4;
    if (ht & HeaderType.WithSessionId)
        offset += 4;
    if (ht & HeaderType.WithTimestamp)
        offset += 4;

    if (ht & HeaderType.UseExtendedHeader)
    {
        auto eh = cast(const(ExtendedHeader)*)(ptr + offset);
        if (eh.messageInfo & MessageInfo.Verbose)
            return 0; // Verbose message has no ID
        offset += ExtendedHeader.sizeof;
    }

    // Non-Verbose: Message ID is in the first 4 bytes of payload
    // Standard DLT says for Non-Verbose, Message ID is mandatory? 
    // Usually yes. Some implementations might vary, but we'll follow common practice.
    const(ubyte)[] payload = (ptr + offset)[0 .. 4];
    return readValue!uint(payload, msbf);
}

@("getHeaderSize: Min Header (UEH=0)")
unittest
{
    // Test 1: Standard Header only
    // HT: 001 (Use Extended) 0 (No) -> 0?
    // Let's verify getHeaderSize

    // Case A: Min Header (UEH=0)
    // HT: 0
    ubyte[] msg = [0, 0, 0, 0];
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = 0;
    assert(getHeaderSize(msg.ptr) == 4);
}

@("getHeaderSize: With ECU ID (WEID=1)")
unittest
{
    // Case B: With ECU ID (WEID=1) -> Bit 2? 
    // HeaderType Enum: UseExtendedHeader = 1, WithEcuId = 4
    ubyte[] msg = [0, 0, 0, 0, 65, 66, 67, 68]; // +4 bytes ECU
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = HeaderType.WithEcuId; // 4
    assert(getHeaderSize(msg.ptr) == 8);
}

@("getHeaderSize: Extended Header")
unittest
{
    // Case C: Extended Header
    // HT: UseExtendedHeader (1)
    ubyte[] msg = new ubyte[4 + 10]; // 4 std + 10 ext
    StandardHeader* header = cast(StandardHeader*) msg.ptr;
    header.headerType = HeaderType.UseExtendedHeader;
    assert(getHeaderSize(msg.ptr) == 14);
}

unittest
{
    import std.stdio;

    writeln("Running DLT Core Tests...");

    // Test 1: Standard Header only
    // HT: 001 (Use Extended) 0 (No) -> 0?
    // Let's verify getHeaderSize

    // Case A: Min Header (UEH=0)
    // HT: 0
    ubyte[] msgA = [0, 0, 0, 0];
    StandardHeader* shA = cast(StandardHeader*) msgA.ptr;
    shA.headerType = 0;
    assert(getHeaderSize(msgA.ptr) == 4);

    // Case B: With ECU ID (WEID=1) -> Bit 2? 
    // HeaderType Enum: UseExtendedHeader = 1, WithEcuId = 4
    ubyte[] msgB = [0, 0, 0, 0, 65, 66, 67, 68]; // +4 bytes ECU
    StandardHeader* shB = cast(StandardHeader*) msgB.ptr;
    shB.headerType = HeaderType.WithEcuId; // 4
    assert(getHeaderSize(msgB.ptr) == 8);

    // Case C: Extended Header
    // HT: UseExtendedHeader (1)
    ubyte[] msgC = new ubyte[4 + 10]; // 4 std + 10 ext
    StandardHeader* shC = cast(StandardHeader*) msgC.ptr;
    shC.headerType = HeaderType.UseExtendedHeader;
    assert(getHeaderSize(msgC.ptr) == 14);

    // Test 2: peekMessageId
    // Need Extended Header + Verbose=0
    // HT = UseExtendedHeader
    // ExtHeader: Verbose = 0.
    // Payload: ID = 0xDEADBEEF

    ubyte[] msgD = new ubyte[20];
    StandardHeader* shD = cast(StandardHeader*) msgD.ptr;
    shD.headerType = HeaderType.UseExtendedHeader | HeaderType.MostSignificantByteFirst;

    ExtendedHeader* ehD = cast(ExtendedHeader*)(msgD.ptr + 4);
    ehD.messageInfo = 0; // Not verbose

    // Payload starts at 4 + 10 = 14
    msgD[14] = 0xDE;
    msgD[15] = 0xAD;
    msgD[16] = 0xBE;
    msgD[17] = 0xEF;

    assert(peekMessageId(msgD.ptr) == 0xDEADBEEF);

    // Case E: Verbose message (Should return 0)
    ehD.messageInfo = MessageInfo.Verbose;
    assert(peekMessageId(msgD.ptr) == 0);

    // Case F: Non-Verbose WITHOUT Extended Header
    ubyte[] msgF = new ubyte[12];
    StandardHeader* shF = cast(StandardHeader*) msgF.ptr;
    shF.headerType = HeaderType.MostSignificantByteFirst; // UEH = 0
    // Payload starts at 4
    msgF[4] = 0x12;
    msgF[5] = 0x34;
    msgF[6] = 0x56;
    msgF[7] = 0x78;
    assert(peekMessageId(msgF.ptr) == 0x12345678);

    writeln("DLT Core Tests Passed.");
}
